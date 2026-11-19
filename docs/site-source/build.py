#!/usr/bin/env python3
"""Build self-contained pages for every supported app language. No third-party dependencies."""
import argparse
import html
import json
import re
from datetime import date
from pathlib import Path
import content_en
import content_ja
import importlib
from add_locales import EXTRA

SOURCE = Path(__file__).resolve().parent
DEST = SOURCE.parent / 'site'
CONFIG = json.loads((SOURCE / 'publisher.json').read_text())
CSS = (SOURCE / 'style.css').read_text()
JS = (SOURCE / 'faq.js').read_text()
ORDER = ['privacy-policy', 'terms-of-use', 'manual', 'faq']
REQUIRED = ['developer_name', 'support_email', 'developer_country']
MISSING = [key for key in REQUIRED if not isinstance(CONFIG.get(key), str) or not CONFIG[key].strip()]
if CONFIG.get('support_email') and not re.fullmatch(r'[^\s<>"@]+@[^\s<>"@]+\.[^\s<>"@]+', CONFIG['support_email']):
    raise SystemExit('support_email must be a plain email address, not a URL.')

LANGUAGES = ['en', 'ja', 'ko', 'fr', 'de', 'it', 'zh-Hans']
LABELS = json.loads((SOURCE / 'locales.json').read_text())
LABELS.update(EXTRA)
LANGUAGE_JS = (SOURCE / 'language.js').read_text()


def pages_for(lang):
    return importlib.import_module('content_' + lang.replace('-', '_')).PAGES


def language_href(current, target, filename):
    return ('' if current == 'en' else '../') + ('' if target == 'en' else target + '/') + filename


def language_menu(lang, filename):
    l = LABELS[lang]
    links = ''.join(f'<a data-language-link href="{language_href(lang, other, filename)}" lang="{other}" hreflang="{other}"' + (' aria-current="true"' if other == lang else '') + f'>{LABELS[other]["native_name"]}</a>' for other in LANGUAGES)
    return f'<details class="language-picker" data-language-picker><summary aria-label="{l["language"]}: {l["native_name"]}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/></svg><span>{l["native_name"]}</span></summary><nav aria-label="{l["language"]}">{links}</nav></details>'

MARK = (SOURCE.parent.parent / 'patternlock/Assets.xcassets/PVMonogram.imageset/PVMonogram.svg').read_text().strip()
ICONS = {
 'privacy-policy':'<rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V7a4 4 0 018 0v3m-4 5v2"/>',
 'terms-of-use':'<path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9zM14 3v6h6M8 13h8M8 17h5"/>',
 'manual':'<path d="M12 5v16M12 5C9 3 5 3 2 4v15c4-1 7-1 10 2 3-3 6-3 10-2V4c-3-1-7-1-10 1z"/>',
 'faq':'<path d="M8 9a4 4 0 118 0c0 3-4 2-4 5m0 3v.1"/><circle cx="12" cy="12" r="10"/>'
}

def esc(value): return html.escape(str(value), quote=True)

def render_copy(value, lang):
    l = LABELS[lang]
    for token, key in [('publisher','developer_name'),('contact','support_email'),('country','developer_country')]:
        supplied = CONFIG.get(key)
        if supplied:
            replacement = esc(supplied)
            if token == 'publisher' and CONFIG.get('company_name'):
                company = esc(CONFIG['company_name'])
                replacement = f'{company} ({l["developer"]}: {esc(supplied)})'
            if token == 'country' and supplied == 'Japan': replacement = l['japan']
            if token == 'contact': replacement = f'<a href="mailto:{esc(supplied)}">{esc(supplied)}</a>'
        else:
            replacement = f'<span class="placeholder">[{l["tbd"] if token == "contact" else l[token]}]</span>'
        value = value.replace('{{' + token + '}}', replacement)
    if '{{' in value: raise ValueError(f'Unknown content token: {value[:120]}')
    return value

def date_label(lang):
    d = date.fromisoformat(CONFIG['updated'])
    if lang in ('ja', 'zh-Hans'): return f'{d.year}年{d.month}月{d.day}日'
    if lang == 'ko': return f'{d.year}년 {d.month}월 {d.day}일'
    months = {
        'fr': ['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'],
        'de': ['Januar','Februar','März','April','Mai','Juni','Juli','August','September','Oktober','November','Dezember'],
        'it': ['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto','settembre','ottobre','novembre','dicembre'],
    }
    if lang in months: return f'{d.day}{"." if lang == "de" else ""} {months[lang][d.month-1]} {d.year}'
    return f'{d:%B} {d.day}, {d.year}'


def draft_notice(lang):
    if not MISSING: return ''
    l=LABELS[lang]
    return f'<div class="draft" role="note"><strong>{l["draft_title"]}</strong> {l["draft_body"]}</div>'


def nav(lang, pages, slug):
    return ''.join(f'<a href="{key}.html"' + (' aria-current="page"' if slug == key else '') + f'>{esc(label)}</a>' for key,label in zip(ORDER,LABELS[lang]['nav_labels']))

def chrome(lang, pages, slug, title, description, lead, main, toc='', home=False):
    l = LABELS[lang]
    filename = 'index.html' if home else slug + '.html'
    alternates = ''.join(f'<link rel="alternate" hreflang="{other}" href="{language_href(lang,other,filename)}">' for other in LANGUAGES)
    alternates += f'<link rel="alternate" hreflang="x-default" href="{language_href(lang,"en",filename)}">'
    draft = draft_notice(lang)
    body = main if home else f'<div class="layout">{toc}<article class="article" aria-labelledby="page-title">{main}</article></div>'
    script = f'<script>\n{LANGUAGE_JS}\n</script>' + (f'<script>\n{JS}\n</script>' if slug == 'faq' else '')
    footerlinks = ''.join(f'<a href="{key}.html">{esc(pages[key]["title"])}</a>' for key in ORDER)
    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{esc(description)}">
<meta name="theme-color" content="#152b35">
<title>{esc(title)} — {esc(CONFIG['app_name'])}</title>
{alternates}
<style>\n{CSS}\n</style>
</head>
<body>
<a class="skip" href="#main">{l['skip']}</a>
<header class="topbar"><div class="shell header-inner">
<a class="brand" href="index.html"><span class="brand-mark" aria-hidden="true">{MARK}</span>{esc(CONFIG['app_name'])}</a>
<nav class="nav" aria-label="{l['navigation']}">{nav(lang,pages,slug)}</nav>
{language_menu(lang,filename)}
</div></header>
<main class="shell" id="main">
<div class="hero{' home-hero' if home else ''}"><div class="eyebrow">{l['home']}</div>
<h1 id="page-title">{esc(title).replace(chr(10),'<br>')}</h1>
<p class="lead">{esc(lead)}</p>
<div class="meta"><span>{l['updated']} <time datetime="{esc(CONFIG['updated'])}">{date_label(lang)}</time></span><span>{l['version']} {esc(CONFIG['app_version'])}</span></div></div>
{draft}
{body}
</main>
<footer class="footer"><div class="shell"><div class="footer-inner"><div><strong>{esc(CONFIG['app_name'])}</strong><p>{l['foot']}</p></div><div class="footer-links">{footerlinks}</div></div><p class="footer-note">{l['support']}: {render_copy('{{contact}}',lang)}</p></div></footer>
{script}
</body>
</html>
'''

def document(lang, pages, slug):
    p, l = pages[slug], LABELS[lang]
    if 'faq' in p:
        tocitems = [(id,title) for id,title,questions in p['faq']]
        content = f'''<form class="search-panel" data-faq-search data-count-template="{esc(l['search_count'])}" role="search" hidden><label for="faq-query">{l['search']}</label><div class="search-row"><input id="faq-query" type="search" autocomplete="off" placeholder="{l['placeholder']}" aria-describedby="search-status"><button type="reset">{l['clear']}</button></div><p id="search-status" class="search-status" data-search-status aria-live="polite" aria-atomic="true"></p></form><p class="empty-state" data-empty hidden>{l['empty']}</p>'''
        for id,title,questions in p['faq']:
            content += f'<section class="section faq-section" id="{id}" aria-labelledby="{id}-title"><h2 id="{id}-title">{esc(title)}</h2>'
            for qid,question,answer in questions:
                content += f'<details class="faq-item" id="{qid}"><summary>{esc(question)}</summary><div class="faq-answer"><p>{render_copy(answer,lang)}</p></div></details>'
            content += '</section>'
    else:
        tocitems = [(s['id'],s['title']) for s in p['sections']]
        content = ''.join(f'<section class="section" id="{s["id"]}" aria-labelledby="{s["id"]}-title"><h2 id="{s["id"]}-title">{esc(s["title"])}</h2>{render_copy(s["body"],lang)}</section>' for s in p['sections'])
    links = ''.join(f'<li><a href="#{id}" data-group-link="{id}">{esc(title)}</a></li>' for id,title in tocitems)
    toc = f'<aside class="toc"><nav aria-label="{l["contents"]}"><p class="toc-label">{l["contents"]}</p><ul>{links}</ul></nav></aside><details class="mobile-toc"><summary>{l["contents"]}</summary><nav aria-label="{l["contents"]}"><ul>{links}</ul></nav></details>'
    return chrome(lang,pages,slug,p['title'],p['description'],p['lead'],content,toc)

def homepage(lang, pages):
    l = LABELS[lang]
    cards = ''
    for slug in ['manual','faq','privacy-policy','terms-of-use']:
        p=pages[slug]
        icon=f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICONS[slug]}</svg>'
        cards += f'<a class="doc-card" href="{slug}.html"><div class="card-top"><span class="card-icon">{icon}</span><span class="arrow" aria-hidden="true">↗</span></div><h2>{esc(p["title"])}</h2><p>{esc(p["description"])}</p></a>'
    qids=['forgot','deleted-app','sync']
    questions={qid:q for _,_,group in pages['faq']['faq'] for qid,q,_ in group}
    quick=''.join(f'<li><a href="faq.html#{qid}">{esc(questions[qid])}</a></li>' for qid in qids)
    main=f'<div class="cards">{cards}</div><section class="home-bottom"><div><h2>{l["help_title"]}</h2><p>{l["help_copy"]}</p><a href="manual.html#start">{l["help_link"]} →</a></div><div><h2>{l["quick_title"]}</h2><ul>{quick}</ul></div></section>'
    return chrome(lang,pages,'index',l['home_title'],l['foot'],l['home_lead'],main,home=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-publisher',action='store_true',help='Fail instead of generating drafts if publisher details are missing.')
    args=parser.parse_args()
    if args.require_publisher and MISSING: parser.error('Missing publisher.json fields: '+', '.join(MISSING))
    for lang in LANGUAGES:
        pages=pages_for(lang)
        target=DEST / ('' if lang == 'en' else lang)
        target.mkdir(parents=True,exist_ok=True)
        (target/'index.html').write_text(homepage(lang,pages),encoding='utf-8')
        for slug in ORDER: (target/(slug+'.html')).write_text(document(lang,pages,slug),encoding='utf-8')
    print(f'Built {len(LANGUAGES)*5} self-contained HTML files in {DEST}')
    if MISSING: print('Publication drafts — complete publisher.json: '+', '.join(MISSING))

if __name__ == '__main__': main()
