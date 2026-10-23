import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0002_enable_row_level_security"),
        ("resolution", "0002_resolutionattempt_candidate_payload"),
    ]

    operations = [
        migrations.CreateModel(
            name="SocialEvidenceThrottleState",
            fields=[
                (
                    "user",
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        primary_key=True,
                        serialize=False,
                        to="core.profile",
                    ),
                ),
                ("window_started_at", models.DateTimeField()),
                ("request_count", models.PositiveIntegerField(default=0)),
            ],
        ),
        migrations.RunSQL(
            sql=("ALTER TABLE resolution_socialevidencethrottlestate ENABLE ROW LEVEL SECURITY;"),
            reverse_sql=("ALTER TABLE resolution_socialevidencethrottlestate DISABLE ROW LEVEL SECURITY;"),
        ),
    ]
