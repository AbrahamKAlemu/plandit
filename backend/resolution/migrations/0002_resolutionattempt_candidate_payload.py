from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("resolution", "0001_initial")]
    operations = [
        migrations.AddField(
            model_name="resolutionattempt",
            name="candidate_payload",
            field=models.JSONField(default=None, null=True),
        )
    ]
