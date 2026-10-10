#!/usr/bin/env python3
"""Build a dependency-free, static-only StudyLens landing bundle."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from urllib.parse import urlsplit
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site-url', default='https://study-lens.no-money-do-you-have-money.com')
    parser.add_argument('--output', type=Path, default=REPO / '.build/landing')
    args = parser.parse_args()
    url = args.site_url.rstrip('/')
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password:
        parser.error('--site-url must be an HTTPS origin without path or credentials')
    output = args.output.resolve()
    if output == REPO or REPO.is_relative_to(output) or (output.is_relative_to(REPO) and not output.is_relative_to(REPO / '.build')):
        parser.error('output must not overwrite repository source')
    output.mkdir(parents=True, exist_ok=True)
    version = plistlib.loads((REPO / 'AppBundle/Info.plist').read_bytes())['CFBundleShortVersionString']
    source = REPO / 'landing'
    html = (source / 'index.html').read_text().replace('__SITE_URL__', escape(url, {'"': '&quot;'})).replace('__APP_VERSION__', version)
    if '__SITE_URL__' in html or '__APP_VERSION__' in html:
        raise RuntimeError('Unresolved landing metadata')
    required = ['lens-poses.webp', 'app-result.webp', 'og-ko.png', 'favicon.svg', 'favicon-32.png', 'apple-touch-icon.png']
    for asset in required:
        if not (source / 'assets' / asset).is_file():
            raise RuntimeError('Missing landing asset: ' + asset)
    (output / 'index.html').write_text(html)
    for name in ['style.css', 'app.js']:
        shutil.copyfile(source / name, output / name)
    (output / 'assets').mkdir(exist_ok=True)
    for asset in required:
        shutil.copyfile(source / 'assets' / asset, output / 'assets' / asset)
    (output / 'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: ' + url + '/sitemap.xml\n')
    (output / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>' + escape(url) + '/</loc></url></urlset>\n')
    revision = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip()
    (output / 'release.json').write_text(json.dumps(dict(app='studylens-landing', revision=revision, site_url=url + '/', app_version=version), indent=2) + '\n')
    print('Built StudyLens landing: ' + str(output))


if __name__ == '__main__':
    main()
