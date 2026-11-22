from django.core.management.base import BaseCommand

from plandit.core.retention import purge_expired


class Command(BaseCommand):
    help = "Delete friends' answers and group plans past their retention limit (plandit.core.retention)."

    def handle(self, *args, **options):
        deleted = purge_expired()
        if not deleted:
            self.stdout.write("No expiry rules registered; nothing to purge.")
        for label, count in deleted.items():
            self.stdout.write(f"{label}: {count} deleted")
