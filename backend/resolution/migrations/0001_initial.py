from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = []
    operations = [
        migrations.CreateModel(
            name="ResolutionAttempt",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("request_id", models.UUIDField(unique=True)),
                ("platform", models.CharField(max_length=16)),
                ("outcome", models.CharField(max_length=32)),
                ("provider", models.CharField(default="fixture", max_length=32)),
                ("candidate_count", models.PositiveSmallIntegerField(default=0)),
                ("latency_ms", models.PositiveIntegerField(default=0)),
                ("idempotency_digest", models.CharField(max_length=64)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"ordering": ["-created_at"]},
        )
    ]
