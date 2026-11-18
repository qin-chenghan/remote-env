try:
    import mock_gpu.autoload  # noqa: F401
except Exception as exc:  # never break the interpreter
    print(f"[mock_gpu] sitecustomize skipped: {exc}")
