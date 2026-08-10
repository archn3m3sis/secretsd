import os,pty,sys,fcntl,termios,struct,re,select,time
cols,rows=int(sys.argv[1]),int(sys.argv[2])
args=[a for a in sys.argv[3:] if a]
BIN=os.environ.get("SD_BIN","./bin/secretsd")
pid,fd=pty.fork()
if pid==0:
    os.environ["COLORTERM"]="truecolor"; os.environ["TERM"]="xterm-256color"
    os.execvp(BIN,[BIN]+args)
fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack("HHHH",rows,cols,0,0))
def drain(t):
    o=b"";e=time.time()+t
    while time.time()<e:
        r,_,_=select.select([fd],[],[],0.08)
        if r:
            try:c=os.read(fd,65536)
            except OSError:break
            if not c:break
            o+=c
        # answer the queries a real terminal answers
        if b'\x1b]11;?' in o[-200:]: os.write(fd,b'\x1b]11;rgb:158e/193a/1e75\x1b\\')
        if b'\x1b[6n'  in o[-200:]: os.write(fd,b'\x1b[15;1R')
    return o
buf=drain(2.6)
os.write(fd,b'j'); buf+=drain(0.5)
os.write(fd,b'k'); buf+=drain(0.8)
os.write(fd,b'q'); drain(0.3)
try: os.waitpid(pid,os.WNOHANG)
except Exception: pass
d=buf.decode('utf-8','replace')
scr=[[' ']*cols for _ in range(rows)]; cy=cx=0; pw=False; i=0
while i<len(d):
    ch=d[i]
    if ch=='\033':
        m=re.match(r'\033\[([0-9;?]*)([A-Za-z])',d[i:])
        if not m:
            m2=re.match(r'\033\][0-9]*;[^\007\033]*(\007|\033\\)',d[i:])
            if m2: i+=m2.end(); continue
            i+=1; continue
        p_,c_=m.group(1),m.group(2)
        if c_=='H':
            pw=False; ps=[int(x) for x in p_.split(';') if x.isdigit()]
            cy=(ps[0]-1) if ps else 0; cx=(ps[1]-1) if len(ps)>1 else 0
        elif c_=='J':
            if p_=='2': scr=[[' ']*cols for _ in range(rows)]
            else:
                for y in range(cy+1,rows): scr[y]=[' ']*cols
                for x in range(cx,cols): scr[cy][x]=' '
        i+=m.end(); continue
    if ch=='\n': pw=False; cy=min(cy+1,rows-1); cx=0
    elif ch=='\r': pw=False; cx=0
    else:
        if pw: cx=0; cy=min(cy+1,rows-1); pw=False
        if 0<=cy<rows and 0<=cx<cols: scr[cy][cx]=ch
        cx+=1
        if cx>=cols: cx=cols-1; pw=True
    i+=1
print("┌"+"─"*cols+"┐")
for r in scr: print("│"+"".join(r)+"│")
print("└"+"─"*cols+"┘")
