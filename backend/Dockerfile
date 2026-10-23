FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .
# collectstatic never touches the database, but settings refuse to load without a DATABASE_URL
# in non-debug mode, so give the build a placeholder.
RUN DJANGO_SECRET_KEY=build-only DJANGO_DEBUG=0 DATABASE_URL=postgresql://build:build@localhost/build \
    python manage.py collectstatic --noinput

EXPOSE 8000
CMD ["sh", "-c", "python manage.py migrate --noinput && gunicorn config.wsgi:application --bind 0.0.0.0:${PORT:-8000} --workers ${WEB_CONCURRENCY:-2} --access-logfile -"]
