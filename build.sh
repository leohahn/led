/Users/leonardohahn/zig/build/zig \
    build-exe \
    /Users/leonardohahn/dev/hed/src/main.zig \
    -lc \
    -lncurses \
    --cache-dir /Users/leonardohahn/dev/hed/zig-cache \
    --global-cache-dir /Users/leonardohahn/.cache/zig \
    --name hed \
    -I /usr/local/Cellar/ncurses/6.3/include \
    -L /use/local/Cellar/ncurses/6.3/lib \
    --enable-cache

