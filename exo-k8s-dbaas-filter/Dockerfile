FROM python:3.11-alpine

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy script
COPY exo-dbaas-filter.py .
RUN chmod +x exo-dbaas-filter.py

# Run as non-root user
RUN adduser -D -u 1000 exoscale
USER exoscale

ENTRYPOINT ["python3", "/app/exo-dbaas-filter.py"]
