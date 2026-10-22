import os

from django.core.management.base import BaseCommand, CommandError

from resolution.providers.ensembledata import EnsembleDataClient, EnsembleDataError


class Command(BaseCommand):
    help = "Fetch caption and platform subtitles for one public TikTok URL."

    def add_arguments(self, parser):
        parser.add_argument("url")

    def handle(self, *args, **options):
        token = os.environ.get("ENSEMBLEDATA_API_TOKEN")
        if not token:
            raise CommandError("Set ENSEMBLEDATA_API_TOKEN before running this command.")
        try:
            evidence = EnsembleDataClient(token).evidence_for(options["url"])
        except EnsembleDataError as error:
            raise CommandError(str(error)) from error

        self.stdout.write(f"Canonical URL: {evidence.canonical_url}")
        self.stdout.write(f"Caption: {evidence.caption or '[none]'}")
        self.stdout.write(
            f"Transcript language: {evidence.transcript_language or '[unknown]'}"
        )
        self.stdout.write("Transcript:")
        self.stdout.write(evidence.transcript or "[none]")
