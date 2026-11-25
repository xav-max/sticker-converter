# Stage 1: Build apngasm (with Zopfli compression)
FROM alpine:latest AS apngasm-builder
RUN apk add --no-cache \
    build-base cmake git libpng-dev zlib-dev zopfli-dev boost-dev
RUN git clone --depth 1 --recursive https://github.com/apngasm/apngasm.git /usr/src/apngasm
WORKDIR /usr/src/apngasm/build
RUN cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. \
    && make -j$(nproc) apngasm-dynamic \
    && make -j$(nproc) apngasm-cli \
    && make install

# Stage 2: Runtime container
FROM alpine:latest

# Install FFmpeg, Bash, Node.js, NPM, Gifsicle, pngquant, librsvg (rsvg-convert), and apngasm runtime libs
RUN apk add --no-cache \
    bash ffmpeg coreutils nodejs npm gifsicle pngquant rsvg-convert \
    libpng zopfli libstdc++ \
    boost-filesystem boost-program_options boost-regex

COPY --from=apngasm-builder /usr/local/bin/apngasm /usr/local/bin/apngasm
COPY --from=apngasm-builder /usr/local/lib/libapngasm* /usr/local/lib/

WORKDIR /app

COPY process_stickers.sh .
RUN chmod +x process_stickers.sh

COPY package.json .
COPY server.js .
COPY public/ public/

RUN npm install

EXPOSE 8080

CMD ["node", "server.js"]
