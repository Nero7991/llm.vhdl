import os, struct, sys
dev=sys.argv[1]; BASE=0xE000; WIN_SEL=0x58; WIN_ADDR=0x5C; WIN_DATA=0x60; XIN=2; XOUT=3; N=4096
fd=os.open(dev, os.O_RDWR)
def wr(o,v): os.pwrite(fd, struct.pack('<I', v & 0xFFFFFFFF), BASE+o)
def rd(o): return struct.unpack('<I', os.pread(fd, 4, BASE+o))[0]
def s16(v): v&=0xFFFF; return v-65536 if v>=32768 else v
exp=[(i*13)%20000-10000 for i in range(N)]
wr(WIN_SEL, XIN); wr(WIN_ADDR, 0)
for v in exp: wr(WIN_DATA, v & 0xFFFF)
print("WIN_ADDR after 4096 writes:", rd(WIN_ADDR))
wr(WIN_SEL, XOUT); wr(WIN_ADDR, 0); r=[s16(rd(WIN_DATA)) for _ in range(N)]
bad=[i for i in range(N) if r[i]!=exp[i]]
print("pread/pwrite loopback on %s: %d of %d differ; WIN_ADDR after 4096 reads: %d" % (dev, len(bad), N, rd(WIN_ADDR)))
