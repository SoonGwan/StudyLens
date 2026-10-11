//! RS256 ID token verification against the issuer's published keys.

use super::AuthError;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rsa::{BigUint, Pkcs1v15Sign, RsaPublicKey};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

pub const ISSUER: &str = "https://auth.openai.com";

#[derive(Debug, Clone, Deserialize)]
pub struct JwkSet {
    pub keys: Vec<Jwk>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Jwk {
    pub kty: String,
    pub kid: String,
    pub n: Option<String>,
    pub e: Option<String>,
    #[serde(rename = "use")]
    pub usage: Option<String>,
    pub alg: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub subject: String,
    pub email: Option<String>,
}

pub fn verify(jwt: &str, keys: &JwkSet, client_id: &str, nonce: &str, now: f64) -> Result<Identity, AuthError> {
    let invalid = || AuthError::InvalidIdentity;
    let parts: Vec<&str> = jwt.split('.').collect();
    let [header, payload, signature] = parts[..] else { return Err(invalid()) };
    let decode = |s: &str| URL_SAFE_NO_PAD.decode(s).map_err(|_| invalid());
    let header: Value = serde_json::from_slice(&decode(header)?).map_err(|_| invalid())?;
    if header["alg"] != "RS256" {
        return Err(invalid());
    }
    let kid = header["kid"].as_str().ok_or_else(invalid)?;
    let jwk = keys
        .keys
        .iter()
        .find(|k| {
            k.kid == kid
                && k.kty == "RSA"
                && k.usage.as_deref().map_or(true, |u| u == "sig")
                && k.alg.as_deref().map_or(true, |a| a == "RS256")
        })
        .ok_or_else(invalid)?;
    let n = decode(jwk.n.as_deref().ok_or_else(invalid)?)?;
    let e = decode(jwk.e.as_deref().ok_or_else(invalid)?)?;
    if n.is_empty() || e.is_empty() {
        return Err(invalid());
    }
    let key = RsaPublicKey::new(BigUint::from_bytes_be(&n), BigUint::from_bytes_be(&e)).map_err(|_| invalid())?;
    let digest = Sha256::digest(format!("{}.{}", parts[0], parts[1]).as_bytes());
    key.verify(Pkcs1v15Sign::new::<Sha256>(), &digest, &decode(signature)?).map_err(|_| invalid())?;

    let claims: Value = serde_json::from_slice(&decode(payload)?).map_err(|_| invalid())?;
    let subject = claims["sub"].as_str().filter(|s| !s.is_empty()).ok_or_else(invalid)?;
    let expiry = claims["exp"].as_f64().ok_or_else(invalid)?;
    if claims["iss"] != ISSUER || expiry <= now || claims["nonce"] != nonce {
        return Err(invalid());
    }
    let audiences: Vec<&str> = match &claims["aud"] {
        Value::String(s) => vec![s.as_str()],
        Value::Array(list) => list.iter().filter_map(Value::as_str).collect(),
        _ => vec![],
    };
    let azp = claims["azp"].as_str();
    if !audiences.contains(&client_id) || (audiences.len() > 1 && azp != Some(client_id)) || azp.is_some_and(|a| a != client_id) {
        return Err(invalid());
    }
    if claims["nbf"].as_f64().is_some_and(|nbf| nbf > now + 30.0) {
        return Err(invalid());
    }
    Ok(Identity { subject: subject.to_string(), email: claims["email"].as_str().map(str::to_string) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::traits::PublicKeyParts;
    use rsa::RsaPrivateKey;
    use serde_json::json;

    #[test]
    fn identity_requires_valid_signature_and_claims() {
        let private = RsaPrivateKey::new(&mut rand::thread_rng(), 1024).unwrap();
        let public = private.to_public_key();
        let keys = JwkSet {
            keys: vec![Jwk {
                kty: "RSA".into(),
                kid: "test-key".into(),
                n: Some(URL_SAFE_NO_PAD.encode(public.n().to_bytes_be())),
                e: Some(URL_SAFE_NO_PAD.encode(public.e().to_bytes_be())),
                usage: Some("sig".into()),
                alg: Some("RS256".into()),
            }],
        };
        let sign = |claims: &Value| {
            let header = URL_SAFE_NO_PAD.encode(json!({"alg":"RS256","kid":"test-key"}).to_string());
            let payload = URL_SAFE_NO_PAD.encode(claims.to_string());
            let message = format!("{header}.{payload}");
            let signature = private.sign(Pkcs1v15Sign::new::<Sha256>(), &Sha256::digest(message.as_bytes())).unwrap();
            format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature))
        };
        let claims = json!({"iss": ISSUER, "aud": "oaiapp_test", "nonce": "nonce", "exp": 2000, "sub": "subject", "email": "a@b.c"});
        let token = sign(&claims);
        assert_eq!(verify(&token, &keys, "oaiapp_test", "nonce", 1000.0).unwrap().subject, "subject");
        for (key, value) in [("iss", json!("https://other.example")), ("aud", json!("oaiapp_other")), ("nonce", json!("wrong")), ("exp", json!(900))] {
            let mut changed = claims.clone();
            changed[key] = value;
            assert!(verify(&sign(&changed), &keys, "oaiapp_test", "nonce", 1000.0).is_err(), "{key}");
        }
        let pieces: Vec<&str> = token.split('.').collect();
        let forged = format!("{}.{}.{}", pieces[0], pieces[1], URL_SAFE_NO_PAD.encode([0u8; 128]));
        assert!(verify(&forged, &keys, "oaiapp_test", "nonce", 1000.0).is_err());
    }
}
