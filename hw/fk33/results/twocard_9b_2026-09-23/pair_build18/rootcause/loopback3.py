import mmap, os, struct, sys
dev = sys.argv[1]
BASE=0xE000; WIN_SEL=0x58; WIN_ADDR=0x5C; WIN_DATA=0x60; XIN=2; XOUT=3; N=4096
fd=os.open(dev, os.O_RDWR|os.O_SYNC); m=mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE)
def wr(o,v): m[BASE+o:BASE+o+4]=struct.pack('<I', v & 0xFFFFFFFF)
def rd(o): return struct.unpack('<I', m[BASE+o:BASE+o+4])[0]
def s16(v): v&=0xFFFF; return v-65536 if v>=32768 else v
def ranges(idx):
    out=[]; 
    for i in idx:
        if out and i==out[-1][1]+1: out[-1][1]=i
        else: out.append([i,i])
    return out
exp=[(i*13)%20000-10000 for i in range(N)]
wr(WIN_SEL, XIN); wr(WIN_ADDR, 0)
for v in exp: wr(WIN_DATA, v & 0xFFFF)
# R1: one auto-increment stream from 0
wr(WIN_SEL, XOUT); wr(WIN_ADDR, 0); r1=[s16(rd(WIN_DATA)) for _ in range(N)]
bad1=[i for i in range(N) if r1[i]!=exp[i]]
print("R1 auto-increment stream: %d bad; ranges %s; sample %s" % (len(bad1), ranges(bad1)[:6], [(i,exp[i],r1[i]) for i in bad1[:4]]))
# R2: re-seed WIN_ADDR every 256 words
r2=[]
for s in range(0,N,256):
    wr(WIN_SEL, XOUT); wr(WIN_ADDR, s); r2+= [s16(rd(WIN_DATA)) for _ in range(256)]
bad2=[i for i in range(N) if r2[i]!=exp[i]]
print("R2 re-seeded every 256: %d bad; ranges %s" % (len(bad2), ranges(bad2)[:6]))
# R3: explicit address per word for a sparse set
bad3=[]
for i in list(range(2040,2060))+list(range(3060,3080))+[4090,4095]:
    wr(WIN_ADDR, i); v=s16(rd(WIN_DATA))
    if v!=exp[i]: bad3.append((i,exp[i],v))
print("R3 explicit per-word: bad", bad3[:8])
# R4: WIN_ADDR value after a full 4096 stream
wr(WIN_ADDR, 0); [rd(WIN_DATA) for _ in range(N)]; print("R4 WIN_ADDR after 4096 reads:", rd(WIN_ADDR))
