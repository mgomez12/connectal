#!/usr/bin/python
# Copyright (c) 2014-2015 Quanta Research Cambridge, Inc
# Copyright (c) 2015 Connectal Project
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#

import os, sys, re
import argparse

argparser = argparse.ArgumentParser("Preprocess BSV files.")
argparser.add_argument('bsvfile', help='BSV files to parse', nargs='+')
argparser.add_argument('-D', '--bsvdefine', default=[], help='BSV define', action='append')
argparser.add_argument('-I', '--include', help='Specify import/include directories', default=[], action='append')
argparser.add_argument('--bsvpath', default=[], help='directories to add to bsc search path', action='append')
argparser.add_argument('-v', '--verbose', help='Display verbose information messages', action='store_true')

def preprocess(sourcefilename, source, defs, bsvpath):
    # convert defs to a dict
    # defs could be a list of symbol or symbol=value
    if type(defs) == list:
        d = {}
        for sym in defs:
            if '=' in sym:
                (s, val) = sym.split('=')
                d[s] = val
            else:
                d[sym] = True
        defs = d
    stack = [(True,True)]
    def nexttok(s):
        k = re.search('[^A-Za-z0-9~_]', s)
        if k:
            sym = s[:k.start()]
            s = s[k.end():]
            return (sym, s)
        else:
            return (s, '')
    lines = source.splitlines()
    outlines = []
    while lines:
        line = lines[0]
        lines = lines[1:]
        cond  = stack[-1][0]
        valid = stack[-1][1]

        commentStart = re.match('//', line)
        if commentStart:
            s = line[0:commentStart.start()]
        else:
            s = line
        i = re.search('`', s)
        if not i:
            if valid:
                outlines.append(line)
            else:
                outlines.append('//SKIPPED %s' % line)
            continue
        pre = s[:i.end()-1]
        s = s[i.end():]
        (tok, s) = nexttok(s)
        if tok == 'ifdef':
            (sym, s) = nexttok(s)
            new_cond = sym in defs
            new_valid = new_cond and valid
            stack.append((new_cond,new_valid))
        elif tok == 'ifndef':
            (sym, s) = nexttok(s)
            new_cond = not sym in defs
            new_valid = valid and new_cond
            stack.append((new_cond,new_valid))
        elif tok == 'else':
            new_cond = not cond
            stack.pop()
            valid = stack[-1][1]
            stack.append((new_cond,valid))
        elif tok == 'elsif':
            stack.pop()
            valid = stack[-1][1]
            (sym, s) = nexttok(s)
            new_cond = sym in defs
            new_valid = new_cond and valid
            stack.append((new_cond,new_valid))
        elif tok == 'endif':
            stack.pop()
            valid = stack[-1][1]
        elif tok == 'define':
            (sym, s) = nexttok(s)
            defs.append(sym)
        elif tok == 'include':
            m = re.search('"?([-_A-Za-z0-9.]+)"?', s)
            if not m:
                sys.stderr.write('syntax.preprocess %s: could not find file in line {%s}\n' % (sourcefilename, s))
            filename = m.group(1)
            inc = ''
            for d in bsvpath:
                fn = os.path.join(d, filename)
                if os.path.exists(fn):
                    inc = open(fn).read()
                    break
            if not inc:
                sys.stderr.write('syntax.preprocess %s: did not find included file %s in path\n' % (sourcefilename, filename))
            outlines.append('//`include "%s"' % filename)
            lines.extend(inc.splitlines())
            continue
        elif re.match('[A-Z][A-Za-z0-9_]*', tok):
            ## must be an undefined variable
            sys.stderr.write('syntax.preprocess %s: preprocessor variable `%s\n' % (sourcefilename, tok))
        else:
            sys.stderr.write('syntax.preprocess %s: unhandled preprocessor token %s\n' % (sourcefilename, tok))
            assert(tok in ['ifdef', 'ifndef', 'else', 'endif', 'define'])
        outlines.append('//PREPROCESSED: %s' % line)

    return '%s\n' % '\n'.join(outlines)

if __name__=='__main__':
    options = argparser.parse_args()
    for f in options.bsvfile:
        preprocessed = preprocess(f, open(f).read(), options.bsvdefine, options.include + options.bsvpath)
        print preprocessed
        
