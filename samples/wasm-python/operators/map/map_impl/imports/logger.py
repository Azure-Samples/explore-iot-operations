"""
based on https://github.com/WebAssembly/wasi-logging/blob/main/wit/logging.wit
"""
from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some


class Level(Enum):
    """
    A log level, describing a kind of message.
    """
    TRACE = 0
    DEBUG = 1
    INFO = 2
    WARN = 3
    ERROR = 4
    CRITICAL = 5


def log(level: Level, context: str, message: str) -> None:
    """
    Emit a log message.
    
    A log message has a `level` describing what kind of message is being
    sent, a context, which is an uninterpreted string meant to help
    consumers group similar messages, and a string containing the message
    text.
    """
    raise NotImplementedError

