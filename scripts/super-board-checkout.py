"""Validate configured checkout identity before launcher startup work."""
from pathlib import Path


def require_checkout(actual_root: Path, configured_path: str | None) -> Path:
    actual = actual_root.resolve()
    if configured_path is None:
        return actual
    if not isinstance(configured_path, str) or not configured_path.strip():
        raise ValueError(f'Invalid repo.path {configured_path!r}; actual checkout: {actual}')
    try:
        configured = Path(configured_path)
        if not configured.is_absolute():
            configured = actual / configured
        configured = configured.resolve()
    except (OSError, RuntimeError, ValueError) as error:
        raise ValueError(f'Invalid repo.path {configured_path!r}; actual checkout: {actual}: {error}') from error
    if actual != configured:
        raise ValueError(f'Checkout mismatch: actual={actual}; configured={configured}')
    return actual
