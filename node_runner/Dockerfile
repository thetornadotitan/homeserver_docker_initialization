FROM node:20-alpine

RUN apk add --no-cache git openssh-client bash

WORKDIR /app

# tiny entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000
ENTRYPOINT ["/entrypoint.sh"]
