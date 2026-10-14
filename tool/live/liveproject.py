#!/usr/bin/env python3
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'e2e'))
from mkproject import form_json, install_extensions

PACKAGE = 'dev.rush.live.app'
COMPANION = 'RushLive'


def generic_handler(component, event):
    params = [p['name'] for p in event['params']]
    variables = ' '.join(f'${p}' for p in ['component', 'notAlreadyHandled', *params])
    values = ' '.join(f'(lexical-value ${p})' for p in params)
    arguments = (f'(call-yail-primitive make-yail-list (*list-for-runtime* {values}) '
                 f"'({' '.join('any' for _ in params)}) \"make a list\")")
    return (f'(define-generic-event {component["name"]} {event["name"]} ({variables}) (set-this-form)\n'
            f"  (call-component-method '{COMPANION}1 'Report "
            f'(*list-for-runtime* (lexical-value $component) "{event["name"]}" {arguments}) '
            f"'(component text list)))")


def yail(components):
    handlers = '\n'.join(generic_handler(c, e) for c in components if c['name'] != COMPANION
                         for e in c['events'])
    return f'''#|
$Source $Yail
|#

(define-form {PACKAGE}.Screen1 Screen1 #f)
(require <com.google.youngandroid.runtime>)
(do-after-form-creation (set-and-coerce-property! 'Screen1 'AppName "Rush Live" 'text)
 (set-and-coerce-property! 'Screen1 'TitleVisible #f 'boolean))
(add-component Screen1 dev.rush.live.{COMPANION} {COMPANION}1 )
{handlers}
(init-runtime)
'''


def main(project, *aixes):
    components = install_extensions(project, aixes)
    source = os.path.join(project, 'src', *PACKAGE.split('.'))
    os.makedirs(source, exist_ok=True)
    os.makedirs(os.path.join(project, 'youngandroidproject'), exist_ok=True)
    with open(os.path.join(project, 'youngandroidproject', 'project.properties'), 'w') as f:
        f.write(f'main={PACKAGE}.Screen1\nname=RushLive\nassets=../assets\nsource=../src\nbuild=../build\n'
                'versioncode=1\nversionname=1.0\nuseslocation=False\naname=RushLive\nsizing=Responsive\n'
                'showlistsasjson=True\ntheme=AppTheme.Light.DarkActionBar\n')
    with open(os.path.join(source, 'Screen1.scm'), 'w') as f:
        f.write(f'#|\n$JSON\n{json.dumps(form_json(components))}\n|#\n')
    with open(os.path.join(source, 'Screen1.bky'), 'w') as f:
        f.write('<xml xmlns="http://www.w3.org/1999/xhtml"></xml>\n')
    with open(os.path.join(source, 'Screen1.yail'), 'w') as f:
        f.write(yail(components))
    print(', '.join(c['type'] for c in components))


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit('usage: liveproject.py <project-dir> <aix>...')
    main(*sys.argv[1:])
