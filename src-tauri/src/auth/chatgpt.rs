//! ChatGPT account connections: one self-registered client per account, tokens in the
//! OS credential store, refresh on expiry and revocation on sign-out.

use super::loopback::{self, Callback};
use super::oidc::{self, JwkSet, ISSUER};
use super::{challenge, form, random_value, AuthError};
use crate::secrets::SecretStore;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Notify;

const RESOURCE: &str = "https://api.openai.com/v1";
const SCOPES: &str = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
const VAULT_ACCOUNT: &str = "chatgpt-oauth-vault";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Credentials {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub id_token: String,
    pub scopes: Vec<String>,
    /// Seconds since the Unix epoch.
    pub expires_at: f64,
}

impl Credentials {
    pub fn permits_inference(&self) -> bool {
        self.scopes.iter().any(|s| s == "chatgpt.tokens.use.direct")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub client_id: String,
    pub subject: Option<String>,
    pub email: Option<String>,
    pub credentials: Option<Credentials>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vault {
    profiles: Vec<Profile>,
    active_client_id: Option<String>,
}

/// What the settings window shows; never contains tokens.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSummary {
    pub client_id: String,
    pub label: String,
    pub connected: bool,
    pub permits_inference: bool,
}

pub struct ChatGptAuth {
    http: reqwest::Client,
    store: Arc<dyn SecretStore>,
    host_id: String,
    vault: Mutex<Vault>,
    storage_error: Option<String>,
    refresh_lock: tokio::sync::Mutex<()>,
    cancel: Mutex<Option<Arc<Notify>>>,
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or_default()
}

impl ChatGptAuth {
    pub fn new(store: Arc<dyn SecretStore>, host_id: String) -> Self {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .build()
            .expect("HTTP client");
        // Do not overwrite existing registrations if the credential store can't be read.
        let (vault, storage_error) = match store.load(VAULT_ACCOUNT) {
            Ok(Some(json)) => match serde_json::from_str(&json) {
                Ok(vault) => (vault, None),
                Err(_) => (Vault::default(), Some("저장된 ChatGPT 연결 정보를 읽지 못했습니다.".to_string())),
            },
            Ok(None) => (Vault::default(), None),
            Err(error) => (Vault::default(), Some(error)),
        };
        Self { http, store, host_id, vault: Mutex::new(vault), storage_error, refresh_lock: Default::default(), cancel: Mutex::new(None) }
    }

    pub fn profiles(&self) -> (Vec<ProfileSummary>, Option<String>) {
        let vault = self.vault.lock().unwrap();
        let summaries = vault
            .profiles
            .iter()
            .map(|p| ProfileSummary {
                client_id: p.client_id.clone(),
                label: format!("{} · {}", p.email.as_deref().unwrap_or("ChatGPT 계정"), &p.client_id[p.client_id.len().saturating_sub(6)..]),
                connected: p.credentials.is_some(),
                permits_inference: p.credentials.as_ref().is_some_and(Credentials::permits_inference),
            })
            .collect();
        (summaries, vault.active_client_id.clone())
    }

    pub fn active_permits_inference(&self) -> bool {
        let vault = self.vault.lock().unwrap();
        active(&vault).and_then(|p| p.credentials.as_ref()).is_some_and(Credentials::permits_inference)
    }

    pub fn select_profile(&self, client_id: &str) -> Result<(), AuthError> {
        self.check_storage()?;
        let mut vault = self.vault.lock().unwrap();
        if vault.profiles.iter().any(|p| p.client_id == client_id) {
            vault.active_client_id = Some(client_id.to_string());
            self.persist(&vault)?;
        }
        Ok(())
    }

    pub fn cancel_sign_in(&self) {
        if let Some(cancel) = self.cancel.lock().unwrap().as_ref() {
            cancel.notify_one();
        }
    }

    pub async fn sign_in(&self, new_account: bool, request_consent: bool, open_browser: impl FnOnce(&str) -> Result<(), String>) -> Result<(), AuthError> {
        self.check_storage()?;
        let previous = if new_account { None } else { active(&self.vault.lock().unwrap()).cloned() };
        let (state, nonce, verifier) = (random_value(), random_value(), random_value());
        let cancel = Arc::new(Notify::new());
        *self.cancel.lock().unwrap() = Some(cancel.clone());
        let host_id = self.host_id.clone();
        let callback = loopback::authorize(
            &state,
            |redirect_uri| {
                let url = authorization_url(previous.as_ref(), &host_id, redirect_uri, &state, &nonce, &verifier, request_consent);
                open_browser(&url).map_err(|_| AuthError::Cancelled)
            },
            cancel,
        )
        .await;
        *self.cancel.lock().unwrap() = None;
        let callback = callback?;
        let client_id = issued_client_id(&callback, previous.as_ref().map(|p| p.client_id.as_str()))?;
        // Keep the issued registration even if the code exchange fails.
        {
            let mut vault = self.vault.lock().unwrap();
            if !vault.profiles.iter().any(|p| p.client_id == client_id) {
                vault.profiles.push(Profile { client_id: client_id.clone(), subject: None, email: None, credentials: None });
                self.persist(&vault)?;
            }
        }
        let token = self
            .token_request(&[
                ("grant_type", "authorization_code"),
                ("client_id", &client_id),
                ("code", &callback.code),
                ("code_verifier", &verifier),
                ("redirect_uri", &callback.redirect_uri),
                ("resource", RESOURCE),
            ])
            .await?;
        let id_token = token.id_token.clone().ok_or(AuthError::InvalidIdentity)?;
        let identity = self.validate_identity(&id_token, &client_id, &nonce).await?;
        if previous.as_ref().and_then(|p| p.subject.as_deref()).is_some_and(|s| s != identity.subject) {
            return Err(AuthError::InvalidIdentity);
        }
        let mut vault = self.vault.lock().unwrap();
        let profile = vault.profiles.iter_mut().find(|p| p.client_id == client_id).ok_or(AuthError::InvalidCallback)?;
        profile.subject = Some(identity.subject);
        profile.email = identity.email;
        profile.credentials = Some(token.credentials(id_token)?);
        vault.active_client_id = Some(client_id);
        self.persist(&vault)
    }

    pub async fn access_token(&self) -> Result<String, AuthError> {
        self.check_storage()?;
        let _guard = self.refresh_lock.lock().await;
        let profile = active(&self.vault.lock().unwrap()).cloned().ok_or(AuthError::NotConnected)?;
        let credentials = profile.credentials.clone().ok_or(AuthError::NotConnected)?;
        if !credentials.permits_inference() {
            return Err(AuthError::PermissionMissing);
        }
        if credentials.expires_at - now() > 60.0 {
            return Ok(credentials.access_token);
        }
        let refresh_token = credentials.refresh_token.clone().ok_or(AuthError::NotConnected)?;
        let result = self
            .token_request(&[("grant_type", "refresh_token"), ("client_id", &profile.client_id), ("refresh_token", &refresh_token), ("resource", RESOURCE)])
            .await;
        let mut vault = self.vault.lock().unwrap();
        let token = match result {
            Ok(token) => token,
            Err(AuthError::OAuth(code)) => {
                const TERMINAL: &[&str] = &["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"];
                if TERMINAL.contains(&code.as_str()) {
                    if let Some(p) = vault.profiles.iter_mut().find(|p| p.client_id == profile.client_id) {
                        p.credentials = None;
                    }
                    self.persist(&vault)?;
                }
                return Err(AuthError::OAuth(code));
            }
            Err(error) => return Err(error),
        };
        let id_token = token.id_token.clone().unwrap_or(credentials.id_token);
        let updated = token.credentials(id_token)?;
        if updated.refresh_token.is_none() {
            return Err(AuthError::OAuth("missing_refresh_token".into()));
        }
        let stored = vault.profiles.iter_mut().find(|p| p.client_id == profile.client_id).ok_or(AuthError::NotConnected)?;
        stored.credentials = Some(updated.clone());
        self.persist(&vault)?;
        if !updated.permits_inference() {
            return Err(AuthError::PermissionMissing);
        }
        Ok(updated.access_token)
    }

    /// Always clears local tokens; returns false if remote revocation wasn't confirmed.
    pub async fn sign_out(&self) -> Result<bool, AuthError> {
        let Some(profile) = active(&self.vault.lock().unwrap()).cloned() else { return Ok(true) };
        let mut revoked = true;
        if let Some(refresh_token) = profile.credentials.as_ref().and_then(|c| c.refresh_token.clone()) {
            revoked = self.revoke(&profile.client_id, &refresh_token).await.unwrap_or(false);
        }
        let mut vault = self.vault.lock().unwrap();
        if let Some(p) = vault.profiles.iter_mut().find(|p| p.client_id == profile.client_id) {
            p.credentials = None;
        }
        self.persist(&vault)?;
        Ok(revoked)
    }

    async fn revoke(&self, client_id: &str, refresh_token: &str) -> Result<bool, AuthError> {
        let discovery = self.discovery().await?;
        let endpoint = discovery["revocation_endpoint"].as_str().filter(|u| trusted(u)).ok_or(AuthError::InvalidIdentity)?;
        let response = self
            .http
            .post(endpoint)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form(&[("token", refresh_token), ("token_type_hint", "refresh_token"), ("client_id", client_id)]))
            .send()
            .await
            .map_err(|_| AuthError::InvalidIdentity)?;
        Ok(response.status().as_u16() == 200)
    }

    fn check_storage(&self) -> Result<(), AuthError> {
        match &self.storage_error {
            Some(error) => Err(AuthError::Storage(error.clone())),
            None => Ok(()),
        }
    }

    fn persist(&self, vault: &Vault) -> Result<(), AuthError> {
        self.check_storage()?;
        let json = serde_json::to_string(vault).map_err(|e| AuthError::Storage(e.to_string()))?;
        self.store.save(VAULT_ACCOUNT, &json).map_err(AuthError::Storage)
    }

    async fn token_request(&self, fields: &[(&str, &str)]) -> Result<TokenResponse, AuthError> {
        let response = self
            .http
            .post(format!("{ISSUER}/api/accounts/oauth/token"))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form(fields))
            .send()
            .await
            .map_err(|_| AuthError::OAuth("token_request_failed".into()))?;
        let status = response.status().as_u16();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        if status != 200 {
            return Err(AuthError::OAuth(body["error"].as_str().unwrap_or("token_request_failed").into()));
        }
        serde_json::from_value(body).map_err(|_| AuthError::InvalidIdentity)
    }

    async fn discovery(&self) -> Result<Value, AuthError> {
        let response = self.http.get(format!("{ISSUER}/.well-known/openid-configuration")).send().await.map_err(|_| AuthError::InvalidIdentity)?;
        if response.status().as_u16() != 200 {
            return Err(AuthError::InvalidIdentity);
        }
        let document: Value = response.json().await.map_err(|_| AuthError::InvalidIdentity)?;
        if document["issuer"] != ISSUER || !document["jwks_uri"].as_str().is_some_and(trusted) {
            return Err(AuthError::InvalidIdentity);
        }
        Ok(document)
    }

    async fn validate_identity(&self, jwt: &str, client_id: &str, nonce: &str) -> Result<oidc::Identity, AuthError> {
        let discovery = self.discovery().await?;
        let jwks = discovery["jwks_uri"].as_str().ok_or(AuthError::InvalidIdentity)?;
        let response = self.http.get(jwks).send().await.map_err(|_| AuthError::InvalidIdentity)?;
        if response.status().as_u16() != 200 {
            return Err(AuthError::InvalidIdentity);
        }
        let keys: JwkSet = response.json().await.map_err(|_| AuthError::InvalidIdentity)?;
        oidc::verify(jwt, &keys, client_id, nonce, now())
    }
}

fn active(vault: &Vault) -> Option<&Profile> {
    vault.profiles.iter().find(|p| Some(&p.client_id) == vault.active_client_id.as_ref())
}

fn trusted(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|u| {
        u.scheme() == "https" && u.host_str() == Some("auth.openai.com") && u.username().is_empty() && u.password().is_none() && u.port().map_or(true, |p| p == 443)
    })
}

pub fn authorization_url(profile: Option<&Profile>, host_id: &str, redirect_uri: &str, state: &str, nonce: &str, verifier: &str, request_consent: bool) -> String {
    let code_challenge = challenge(verifier);
    let mut fields: Vec<(&str, &str)> = vec![
        ("client_id", profile.map_or("dynamic_agent_client", |p| p.client_id.as_str())),
        ("ext_agent_host_id", host_id),
        ("response_type", "code"),
        ("redirect_uri", redirect_uri),
        ("scope", SCOPES),
        ("resource", RESOURCE),
        ("state", state),
        ("nonce", nonce),
        ("code_challenge_method", "S256"),
        ("code_challenge", &code_challenge),
    ];
    if profile.is_none() {
        fields.push(("agent_name_hint", "StudyLens"));
    }
    if let Some(token) = profile.and_then(|p| p.credentials.as_ref()) {
        fields.push(("id_token_hint", &token.id_token));
    }
    if let Some(email) = profile.and_then(|p| p.email.as_deref()) {
        fields.push(("login_hint", email));
    }
    if request_consent {
        fields.push(("prompt", "consent"));
    }
    format!("{ISSUER}/api/accounts/authorize?{}", form(&fields))
}

/// A returning connection must keep its registration; a new one must be issued a real client.
pub fn issued_client_id(callback: &Callback, previous: Option<&str>) -> Result<String, AuthError> {
    if let Some(previous) = previous {
        if callback.client_id.as_deref().is_some_and(|id| id != previous) {
            return Err(AuthError::InvalidCallback);
        }
        return Ok(previous.to_string());
    }
    match callback.client_id.as_deref() {
        Some(id) if id.starts_with("oaiapp_") && id != "dynamic_agent_client" => Ok(id.to_string()),
        _ => Err(AuthError::InvalidCallback),
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    token_type: String,
    expires_in: f64,
    scope: String,
}

impl TokenResponse {
    fn credentials(&self, id_token: String) -> Result<Credentials, AuthError> {
        if !self.token_type.eq_ignore_ascii_case("bearer") || self.access_token.is_empty() || self.expires_in <= 0.0 {
            return Err(AuthError::InvalidIdentity);
        }
        Ok(Credentials {
            access_token: self.access_token.clone(),
            refresh_token: self.refresh_token.clone(),
            id_token,
            scopes: self.scope.split(' ').map(str::to_string).collect(),
            expires_at: now() + self.expires_in,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemoryStore;

    fn query(url: &str) -> std::collections::HashMap<String, String> {
        url::Url::parse(url).unwrap().query_pairs().into_owned().collect()
    }

    #[test]
    fn authorization_separates_new_registration_and_returning_connection() {
        let new = query(&authorization_url(None, "urn:uuid:test", "http://127.0.0.1:1/auth/callback", "s", "n", "v", false));
        assert_eq!(new["client_id"], "dynamic_agent_client");
        assert_eq!(new["agent_name_hint"], "StudyLens");
        assert!(new["scope"].contains("chatgpt.tokens.use.direct"));
        assert!(!new.contains_key("prompt"));
        let profile = Profile { client_id: "oaiapp_test".into(), subject: Some("sub".into()), email: Some("t@e.com".into()), credentials: None };
        let returning = query(&authorization_url(Some(&profile), "urn:uuid:test", "http://127.0.0.1:2/auth/callback", "s2", "n2", "v2", true));
        assert_eq!(returning["client_id"], "oaiapp_test");
        assert!(!returning.contains_key("agent_name_hint"));
        assert_eq!(returning["prompt"], "consent");
        assert_eq!(returning["ext_agent_host_id"], new["ext_agent_host_id"]);
    }

    #[test]
    fn registration_cannot_be_replaced_during_reauthorization() {
        let callback = Callback { code: "abc".into(), client_id: Some("oaiapp_other".into()), redirect_uri: "http://127.0.0.1:1/auth/callback".into() };
        assert!(issued_client_id(&callback, Some("oaiapp_original")).is_err());
        assert_eq!(issued_client_id(&callback, None).unwrap(), "oaiapp_other");
        let missing = Callback { client_id: None, ..callback };
        assert!(issued_client_id(&missing, None).is_err());
        assert_eq!(issued_client_id(&missing, Some("oaiapp_original")).unwrap(), "oaiapp_original");
    }

    #[tokio::test]
    async fn unexpired_token_is_returned_without_network() {
        let store = Arc::new(MemoryStore::default());
        let vault = Vault {
            profiles: vec![Profile {
                client_id: "oaiapp_x".into(),
                subject: Some("s".into()),
                email: None,
                credentials: Some(Credentials { access_token: "tok".into(), refresh_token: None, id_token: "id".into(), scopes: vec!["chatgpt.tokens.use.direct".into()], expires_at: now() + 3600.0 }),
            }],
            active_client_id: Some("oaiapp_x".into()),
        };
        store.save(VAULT_ACCOUNT, &serde_json::to_string(&vault).unwrap()).unwrap();
        let auth = ChatGptAuth::new(store, "urn:uuid:test".into());
        assert_eq!(auth.access_token().await.unwrap(), "tok");
        assert!(auth.active_permits_inference());
    }

    #[tokio::test]
    async fn missing_inference_scope_is_reported() {
        let store = Arc::new(MemoryStore::default());
        let vault = Vault {
            profiles: vec![Profile {
                client_id: "oaiapp_x".into(),
                subject: None,
                email: None,
                credentials: Some(Credentials { access_token: "tok".into(), refresh_token: None, id_token: "id".into(), scopes: vec!["openid".into()], expires_at: now() + 3600.0 }),
            }],
            active_client_id: Some("oaiapp_x".into()),
        };
        store.save(VAULT_ACCOUNT, &serde_json::to_string(&vault).unwrap()).unwrap();
        let auth = ChatGptAuth::new(store, "h".into());
        assert_eq!(auth.access_token().await.unwrap_err(), AuthError::PermissionMissing);
    }
}
