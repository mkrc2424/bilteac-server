FROM dart:stable
WORKDIR /app
COPY server.dart .
CMD ["dart", "server.dart"]
