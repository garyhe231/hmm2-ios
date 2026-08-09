import zlib, struct, pickle, sys
w,h,px = pickle.load(open('/tmp/icon_px.pkl','rb'))

def write_png(path, W, H, rows):
    def chunk(t,d):
        c=t+d; return struct.pack('>I',len(d))+c+struct.pack('>I',zlib.crc32(c)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(r) for r in rows)
    png=(b'\x89PNG\r\n\x1a\n'
         +chunk(b'IHDR',struct.pack('>IIBBBBB',W,H,8,2,0,0,0))
         +chunk(b'IDAT',zlib.compress(raw,9))
         +chunk(b'IEND',b''))
    open(path,'wb').write(png)

def render(path, SIZE, scale_px, bg_top, bg_bot):
    art = SIZE if scale_px is None else scale_px
    art = (art//w)*w                      # 保证整数倍，像素不失真
    o   = (SIZE-art)//2
    k   = art//w
    rows=[]
    for y in range(SIZE):
        t=y/(SIZE-1)
        br=int(bg_top[0]+(bg_bot[0]-bg_top[0])*t)
        bg_=int(bg_top[1]+(bg_bot[1]-bg_top[1])*t)
        bb=int(bg_top[2]+(bg_bot[2]-bg_top[2])*t)
        row=bytearray()
        sy=(y-o)//k
        for x in range(SIZE):
            c=None
            if o<=y<o+art and o<=x<o+art:
                c=px[sy][(x-o)//k]
            row += bytes(c) if c else bytes((br,bg_,bb))
        rows.append(row)
    write_png(path,SIZE,SIZE,rows)
    print("写出", path)

# 深蓝渐变底 + 盾牌占 87.5% (28倍)
render('/tmp/icon_emblem.png', 1024, 896, (26,47,90), (8,16,38))
