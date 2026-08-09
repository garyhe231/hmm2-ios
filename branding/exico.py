import struct, sys
d=open(sys.argv[1],'rb').read()
e=struct.unpack('<I',d[0x3c:0x40])[0]
nsec=struct.unpack('<H',d[e+6:e+8])[0]; opt=struct.unpack('<H',d[e+20:e+22])[0]
magic=struct.unpack('<H',d[e+24:e+26])[0]
nrva=e+24+(92 if magic==0x10b else 108); dd=nrva+4
rsrc_rva,_=struct.unpack('<II',d[dd+16:dd+24])
secs=[]; so=e+24+opt
for i in range(nsec):
    s=d[so+i*40:so+(i+1)*40]
    secs.append((struct.unpack('<I',s[12:16])[0],struct.unpack('<I',s[16:20])[0],struct.unpack('<I',s[20:24])[0]))
def r2o(r):
    for va,vs,pr in secs:
        if va<=r<va+max(vs,1): return pr+(r-va)
base=r2o(rsrc_rva)
def ent(off):
    nn,ni=struct.unpack('<HH',d[off+12:off+16]); o=[]
    for i in range(nn+ni):
        a,b=struct.unpack('<II',d[off+16+i*8:off+24+i*8])
        o.append((a&0x7fffffff,b&0x7fffffff,b&0x80000000))
    return o
imgs=[]
for nid,oto,isd in ent(base):
    if nid!=3: continue
    for n2,o2,_ in ent(base+oto):
        for n3,o3,_ in ent(base+o2):
            drva,dsz=struct.unpack('<II',d[base+o3:base+o3+8])
            imgs.append(d[r2o(drva):r2o(drva)+dsz])
# 组装成单图 .ico
n=1; img=imgs[int(sys.argv[3]) if len(sys.argv)>3 else 0]
w,h,bpp=struct.unpack('<i',img[4:8])[0],abs(struct.unpack('<i',img[8:12])[0])//2,struct.unpack('<H',img[14:16])[0]
hdr=struct.pack('<HHH',0,1,n)
ent1=struct.pack('<BBBBHHII',w%256,h%256,0,0,1,bpp,len(img),6+16)
open(sys.argv[2],'wb').write(hdr+ent1+img)
print(f"写出 {sys.argv[2]}: {w}x{h} {bpp}bpp")
