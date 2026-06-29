import sys
from pathlib import Path

# Make the indexer modules (gaps, loud, analyse_audio, envelope, ...) importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
