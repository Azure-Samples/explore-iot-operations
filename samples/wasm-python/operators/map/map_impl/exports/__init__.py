from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some
from ..imports import types

class Map(Protocol):

    @abstractmethod
    def process(self, message: types.DataModel) -> types.DataModel:
        """
        A map operator takes a message and returns a new message
        that will be passed to the next node in the execution graph.
        """
        raise NotImplementedError

    @abstractmethod
    def init(self, configuration: types.ModuleConfiguration) -> bool:
        """
        The init function called on module load
        """
        raise NotImplementedError


