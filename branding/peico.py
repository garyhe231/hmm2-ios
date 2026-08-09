import struct, sys
f=open(sys.argv[1],'rb'); d=f.read()
e=struct.unpack('<I',d[0x3c:0x40])[0]
assert d[e:e+4]==b'PE\0\0', "not PE"
nsec=struct.unpack('<H',d[e+6:e+8])[0]
opt=struct.unpack('<H',d[e+20:e+22])[0]
magic=struct.unpack('<H',d[e+24:e+26])[0]
nrva=e+24+(92 if magic==0x10b else 108)
ndir=struct.unpack('<I',d[nrva:nrva+4])[0]
dd=nrva+4
rsrc_rva,rsrc_sz=struct.unpack('<II',d[dd+2*8:dd+2*8+8])
secs=[]
so=e+24+opt
for i in range(nsec):
    s=d[so+i*40:so+(i+1)*40]
    secs.append((struct.unpack('<I',s[12:16])[0],struct.unpack('<I',s[16:20])[0],struct.unpack('<I',s[20:24])[0]))
def r2o(rva):
    for va,vs,pr in secs:
        if va<=rva<va+max(vs,1): return pr+(rva-va)
    return None
base=r2o(rsrc_rva)
def entries(off):
    nn,ni=struct.unpack('<HH',d[off+12:off+16]); out=[]
    for i in range(nn+ni):
        eo=off+16+i*8
        nid,oto=struct.unpack('<II',d[eo:eo+8])
        out.append((nid&0x7fffffff if nid&0x80000000 else nid, nid&0x80000000, oto&0x7fffffff, oto&0x80000000))
    return out
found=[]
for nid,isstr,oto,isdir in entries(base):
    if nid!=3 or not isdir: continue      # RT_ICON = 3
    for nid2,_,oto2,isdir2 in entries(base+oto):
        for nid3,_,oto3,_ in entries(base+oto2):
            do=base+oto3
            drva,dsz=struct.unpack('<II',d[do:do+8])
            o=r2o(drva)
            hdr=d[o:o+40]
            w,h,bpp=struct.unpack('<i',hdr[4:8])[0],struct.unpack('<i',hdr[8:12])[0],struct.unpack('<H',hdr[14:16])[0]
            found.append((nid2,w,abs(h)//2,bpp,dsz))
for x in sorted(found): print(f"  ICON id={x[0]:<4} {x[1]}x{x[2]}  {x[3]}bpp  {x[4]} bytes")
if not found: print("  (没有 RT_ICON 资源)")
