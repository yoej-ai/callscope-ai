import logging
from logging.config import dictConfig


def configure_logging(app_env: str) -> None:
    level = "DEBUG" if app_env == "development" else "INFO"
    dictConfig(
        {
            "version": 1,
            "disable_existing_loggers": False,
            "formatters": {
                "default": {
                    "format": "%(asctime)s %(levelname)s %(name)s %(message)s",
                }
            },
            "handlers": {
                "console": {
                    "class": "logging.StreamHandler",
                    "formatter": "default",
                    "level": level,
                }
            },
            "root": {"handlers": ["console"], "level": level},
        }
    )
    logging.getLogger(__name__).debug("Logging configured", extra={"app_env": app_env})
