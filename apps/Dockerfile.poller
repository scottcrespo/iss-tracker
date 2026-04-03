FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY poller.py .
COPY modules/ modules/

RUN useradd --no-create-home --shell /bin/false appuser && chown -R appuser /app
USER appuser

CMD ["python", "poller.py"]
