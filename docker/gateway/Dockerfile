FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir aiohttp>=3.9.0

COPY gateway.py .

EXPOSE 8080

CMD ["python", "gateway.py"]
