# Use a lightweight Alpine Linux base image
FROM alpine:latest

# Install FFmpeg, Bash, Node.js, and NPM
RUN apk add --no-cache bash ffmpeg coreutils nodejs npm

# Set the working directory inside the container
WORKDIR /app

# Copy your bash script into the container and make it executable
COPY process_stickers.sh .
RUN chmod +x process_stickers.sh

# Copy over the Node.js server files
COPY package.json .
COPY server.js .
COPY public/ public/

# Install Node modules
RUN npm install

# Expose the web server port
EXPOSE 8080

# Run the web server when the container starts instead of the bash script directly
CMD ["node", "server.js"]
