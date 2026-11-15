#!/usr/bin/env python3
"""Check generated HTML structure, cross-links, and localization coverage."""
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import content_en
from build import LANGUAGES, LABELS, pages_for, SOURCE
import json

ROOT = Path(__file__).resolve().parent.parent / 'site'
VOID = set('area base br col embed hr img input link meta param source track wbr'.split())

class Page(HTMLParser):
    def __init__(self,path):
        super().__init__(convert_charrefs=True)
        self.path=path
        self.ids=[]
        self.links=[]
        self.refs=[]
        self.stack=[]
        self.h1=0
        self.lang=None
        self.language_links=[]
        self.alternates=[]
        self.feed(path.read_text())
        assert not self.stack, (path,self.stack)
        assert self.h1 == 1, (path,'exactly one h1')
        assert len(self.ids) == len(set(self.ids)), (path,'duplicate IDs',Counter(self.ids))
        assert self.lang == (path.parent.name if path.parent != ROOT else 'en'), (path,'lang')
        assert [a['hreflang'] for a in self.language_links] == LANGUAGES, (path,'language picker coverage')
        assert [a['hreflang'] for a in self.alternates] == LANGUAGES + ['x-default'], (path,'alternate coverage')
        for ref in self.refs: assert ref in self.ids, (path,'unresolved ARIA reference',ref)

    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag not in VOID: self.stack.append(tag)
        if tag == 'html': self.lang=attrs.get('lang')
        if tag == 'h1': self.h1+=1
        if 'id' in attrs: self.ids.append(attrs['id'])
        if 'href' in attrs: self.links.append(attrs['href'])
        if 'data-language-link' in attrs: self.language_links.append(attrs)
        if tag == 'link' and attrs.get('rel') == 'alternate': self.alternates.append(attrs)
        for key in ('aria-labelledby','aria-describedby'):
            self.refs.extend(attrs.get(key,'').split())
        if 'src' in attrs: raise AssertionError((self.path,'unexpected external resource',attrs['src']))
        if tag == 'form': assert 'action' not in attrs, (self.path,'unexpected submission')

    def handle_startendtag(self,tag,attrs):
        self.handle_starttag(tag,attrs)
        if tag not in VOID: self.handle_endtag(tag)

    def handle_endtag(self,tag):
        assert self.stack and self.stack[-1] == tag, (self.path,'mismatched nesting',tag,self.stack[-5:])
        self.stack.pop()

def main():
    pages={path.resolve():Page(path) for path in ROOT.rglob('*.html')}
    assert len(pages)==len(LANGUAGES)*5
    catalog=json.loads((SOURCE.parent.parent/'patternlock/Localizable.xcstrings').read_text())
    app_languages={lang for entry in catalog['strings'].values() for lang in entry.get('localizations',{})}
    assert set(LANGUAGES)==app_languages, ('App/site locale mismatch', app_languages)
    count=0
    for path,page in pages.items():
        assert '{{' not in path.read_text()
        for link in page.language_links:
            target=(path.parent/link['href']).resolve()
            assert target.name==path.name, (path,'switcher changes document',link)
            assert pages[target].lang==link['hreflang'], (path,'switcher wrong language',link)
        for link in page.links:
            assert not link.lower().startswith('mailto:tbd'), (path,'placeholder must not be a mailbox')
        for link in page.links:
            split=urlsplit(link)
            if split.scheme:
                assert split.scheme in {'https','mailto'}, (path,link)
                continue
            assert not split.netloc and not split.path.startswith('/'), (path,'nonportable link',link)
            target=(path.parent/unquote(split.path)).resolve() if split.path else path
            assert target in pages, (path,'missing link target',link)
            if split.fragment: assert unquote(split.fragment) in pages[target].ids, (path,'missing anchor',link)
            count+=1
    for lang in LANGUAGES:
        localized=pages_for(lang)
        assert set(localized)==set(content_en.PAGES), (lang,'missing document')
        for slug,en in content_en.PAGES.items():
            translated=localized[slug]
            assert [s['id'] for s in en.get('sections',[])] == [s['id'] for s in translated.get('sections',[])], (lang,slug,'section coverage')
            for section in translated.get('sections',[]):
                assert section['title'].strip() and section['body'].strip(), (lang,slug,'empty section')
            if 'faq' in en:
                assert [(g[0],[q[0] for q in g[2]]) for g in en['faq']] == [(g[0],[q[0] for q in g[2]]) for g in translated['faq']], (lang,'FAQ coverage')
            if lang!='en': assert translated['lead']!=en['lead'], (lang,slug,'English fallback')
        assert set(LABELS[lang])==set(LABELS['en']), (lang,'UI label coverage')
    print(f'PASS: {len(pages)} HTML pages; {count} relative links/anchors; all {len(LANGUAGES)} app languages; matching sections and FAQs; no external assets.')

if __name__=='__main__': main()
