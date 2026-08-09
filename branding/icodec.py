import struct, zlib, sys
raw=open('/tmp/official.ico','rb').read()
off=struct.unpack('<I',raw[18:22])[0]
img=raw[off:]
w=struct.unpack('<i',img[4:8])[0]; h2=struct.unpack('<i',img[8:12])[0]; h=abs(h2)//2
bpp=struct.unpack('<H',img[14:16])[0]; ncol=struct.unpack('<I',img[32:36])[0] or (1<<bpp)
pal_off=40
pal=[]
for i in range(ncol):
    b,g,r,a=img[pal_off+i*4:pal_off+i*4+4]
    pal.append((r,g,b))
print("调色板:", pal)
xor_off=pal_off+ncol*4
row_bits=w*bpp; row_bytes=((row_bits+31)//32)*4
mask_row=((w+31)//32)*4
and_off=xor_off+row_bytes*h
px=[[None]*w for _ in range(h)]
for y in range(h):
    sy=h-1-y
    row=img[xor_off+sy*row_bytes: xor_off+(sy+1)*row_bytes]
    mrow=img[and_off+sy*mask_row: and_off+(sy+1)*mask_row]
    for x in range(w):
        idx=(row[x//2]>>4) if x%2==0 else (row[x//2]&0xF)
        transparent = (mrow[x//8]>>(7-(x%8))) & 1
        px[y][x]= None if transparent else pal[idx]
# 统计实际用到的颜色
used={}
for r_ in px:
    for c in r_:
        if c: used[c]=used.get(c,0)+1
print("实际用色(按像素数):", sorted(used.items(), key=lambda k:-k[1]))
import pickle
pickle.dump((w,h,px), open('/tmp/icon_px.pkl','wb'))
