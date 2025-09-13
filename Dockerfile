FROM node:20-alpine
WORKDIR /app
COPY server/package.json server/package-lock.json* ./server/
RUN cd server && npm ci --omit=dev
COPY server ./server
ENV NODE_ENV=production
CMD ["npm","--prefix","server","start"]
