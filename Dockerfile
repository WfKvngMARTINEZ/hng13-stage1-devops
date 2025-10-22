FROM node:alpine
WORKDIR /app
COPY . .
RUN npm init -y && npm install
EXPOSE 3000
CMD ["node", "app.js"]