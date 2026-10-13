FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=8080 DATA_DIR=/data
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
VOLUME ["/data"]
EXPOSE 8080
CMD ["node", "src/index.js"]
