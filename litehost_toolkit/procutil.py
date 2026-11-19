#!/usr/bin/env python3
"""Exec into a fresh owned process group, or stop only the recorded group.
Never kills processes by name/port and never trusts an old bare PID file.
"""
import os,signal,sys,time
from pathlib import Path
from lh_common import atomic_json,read_json

def starttime(pid):
    try:return Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19]
    except (FileNotFoundError,ProcessLookupError):return None

def main():
    cmd,path,*args=sys.argv[1:];path=Path(path)
    if cmd=='exec':
        if args and args[0]=='--':args=args[1:]
        if not args:raise ValueError('Missing command')
        os.setsid();pid=os.getpid()
        atomic_json(path,{'pid':pid,'starttime':starttime(pid),'pgid':os.getpgrp(),'sid':os.getsid(0)})
        os.execvpe(args[0],args,os.environ)
    elif cmd=='stop':
        if not path.exists():return 0
        meta=read_json(path);pid=int(meta['pid'])
        if pid<=1 or meta['pgid']!=pid or meta['sid']!=pid or starttime(pid)!=meta['starttime']:return 0
        if os.getpgid(pid)!=pid or os.getsid(pid)!=pid:raise RuntimeError('Process group identity changed')
        try:os.killpg(pid,signal.SIGTERM)
        except ProcessLookupError:return 0
        for _ in range(50):
            if starttime(pid)!=meta['starttime']:return 0
            time.sleep(.2)
        if starttime(pid)==meta['starttime']:
            try:os.killpg(pid,signal.SIGKILL)
            except ProcessLookupError:pass
    else:raise ValueError('Unknown command')
    return 0
if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as e:print('procutil ERROR: '+str(e),file=sys.stderr);raise SystemExit(2)
