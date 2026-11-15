#!/usr/bin/env python3
"""Build, validate and package the static documentation for self-hosting."""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

SOURCE=Path(__file__).resolve().parent
ROOT=SOURCE.parent.parent
OUTPUT=ROOT/'output/documentation'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-publisher',action='store_true')
    args=parser.parse_args()
    subprocess.run([sys.executable,str(SOURCE/'build.py')]+(['--require-publisher'] if args.require_publisher else []),check=True)
    subprocess.run([sys.executable,str(SOURCE/'verify.py')],check=True)
    config=json.loads((SOURCE/'publisher.json').read_text())
    OUTPUT.mkdir(parents=True,exist_ok=True)
    status=('Public support email remains TBD. The pages show a localized draft notice\nand an unlinked email placeholder. Replace it before final publication.'
            if not config.get('support_email') else 'Publisher details are configured. Review the legal content before publication.')
    notes=f'''Pattern HTML documentation — all seven app languages

Publisher: {config['company_name']} (developer: {config['developer_name']})
Country: {config['developer_country']}
Support email: {config.get('support_email') or 'TBD'}
App version: {config['app_version']}
Reviewed: {config['updated']}

STATUS
{status}
Nothing has been published or uploaded.

UPLOAD
Upload the contents of the archive's site/ folder together to any directory on
your server. Keep all language folders in place. Every HTML page is self-contained,
but the language menu and cross-document links need the other pages alongside it.
The 35 pages use relative links and work under a subdirectory or locally from
index.html. Serve text/html with UTF-8. No database, server runtime, CDN, external
fonts, analytics, cookies or third-party scripts are required. Use HTTPS for the
public site. Hosting itself may keep access logs; review its actual practices.

LANGUAGE DIRECTORIES
  site/             English
  site/ja/          日本語 — Japanese
  site/ko/          한국어 — Korean
  site/fr/          Français — French
  site/de/          Deutsch — German
  site/it/          Italiano — Italian
  site/zh-Hans/     简体中文 — Simplified Chinese

Each directory has:
  index.html             Support home
  privacy-policy.html    Privacy Policy
  terms-of-use.html      Terms of Use
  manual.html            Manual
  faq.html               FAQ with 31 questions and local search

The header language menu keeps the current document. With JavaScript enabled it
also keeps the current section. The native menu and links still work without it.
No language preference is stored. Every page declares its language and alternates.

APP STORE CONNECT
Use the final public privacy-policy.html URL for privacy and index.html or
faq.html for support. Each language has its corresponding URL in the directories
above. No domain or public URL is configured or invented in these files.

EDIT AND REBUILD
Source files live in docs/site-source/. Do not upload them as website content.
Edit publisher.json for contact details, content_*.py for document text, and
locales.json / add_locales.py for shared interface text. Then run:
  python3 docs/site-source/package.py
For publication, require a real support address:
  python3 docs/site-source/package.py --require-publisher
This rebuilds docs/site/, checks every internal link and all seven app locales,
and recreates the archive. Supplying the email removes draft notices on rebuild.

PACKAGE
Pattern-HTML-Pages-All-Languages.zip is the current package. The earlier
Pattern-HTML-Pages-EN-JA.zip filename is refreshed as a compatibility copy of the
same complete seven-language archive, so the earlier download link stays usable.

EDITORIAL REVIEW
Confirm business/support practices and actual App Store license configuration.
The legal text is an implementation-informed draft, not a compliance certificate.
Have the relevant legal and language wording reviewed for your markets. Details
and source references are in docs/site-source/IMPLEMENTATION-NOTES.txt.
'''
    (OUTPUT/'UPLOAD-NOTES.txt').write_text(notes,encoding='utf-8')
    archive=OUTPUT/'Pattern-HTML-Pages-All-Languages.zip'
    with ZipFile(archive,'w',compression=ZIP_DEFLATED,compresslevel=9) as z:
        for page in sorted((ROOT/'docs/site').rglob('*.html')):
            z.write(page,Path('site')/page.relative_to(ROOT/'docs/site'))
        z.write(OUTPUT/'UPLOAD-NOTES.txt','UPLOAD-NOTES.txt')
    with ZipFile(archive) as z:
        assert z.testzip() is None
        assert len(z.namelist())==36
    shutil.copyfile(archive,OUTPUT/'Pattern-HTML-Pages-EN-JA.zip')
    print(f'Packaged {archive} ({archive.stat().st_size:,} bytes)')

if __name__=='__main__': main()
