from typing import TypeVar, Generic, Union, Optional, Protocol, Tuple, List, Any, Self
from enum import Flag, Enum, auto
from dataclasses import dataclass
from abc import abstractmethod
import weakref

from ..types import Result, Ok, Err, Some
from ..imports import hybrid_logical_clock

class Buffer:
    """
    A handle to a byter buffer held by the WASM host.
    """
    
    def read(self) -> bytes:
        """
        Read the bytes of this buffer into the module memory.
        """
        raise NotImplementedError
    def __enter__(self):
        """Returns self"""
        return self
                                
    def __exit__(self, *args):
        """
        Release this resource.
        """
        raise NotImplementedError



@dataclass
class BufferOrBytes_Buffer:
    value: Buffer


@dataclass
class BufferOrBytes_Bytes:
    value: bytes


BufferOrBytes = Union[BufferOrBytes_Buffer, BufferOrBytes_Bytes]
"""
A value that is either a host buffer handle or a module buffer.
"""



@dataclass
class BufferOrString_Buffer:
    value: Buffer


@dataclass
class BufferOrString_String:
    value: str


BufferOrString = Union[BufferOrString_Buffer, BufferOrString_String]
"""
A value that is either a host buffer handle or a module string.
"""


@dataclass
class Timestamp:
    """
    A hybrid logical clock for DataModel timestamp
    """
    timestamp: hybrid_logical_clock.Timespec
    counter: int
    node_id: BufferOrString

@dataclass
class MessageProperties:
    user_properties: List[Tuple[BufferOrString, BufferOrString]]

@dataclass
class InlineSchema:
    name: BufferOrString
    content: BufferOrString


@dataclass
class MessageSchema_RegistryReference:
    value: BufferOrString


@dataclass
class MessageSchema_Inline:
    value: InlineSchema


MessageSchema = Union[MessageSchema_RegistryReference, MessageSchema_Inline]


@dataclass
class Message:
    """
    A MQTT message
    """
    timestamp: Timestamp
    topic: BufferOrBytes
    content_type: Optional[BufferOrString]
    payload: BufferOrBytes
    properties: MessageProperties
    schema: Optional[MessageSchema]

@dataclass
class Snapshot:
    """
    A Snapshot
    """
    timestamp: Timestamp
    format: BufferOrString
    width: int
    height: int
    frame: BufferOrBytes


@dataclass
class DataModel_BufferOrBytes:
    value: BufferOrBytes


@dataclass
class DataModel_Message:
    value: Message


@dataclass
class DataModel_Snapshot:
    value: Snapshot


DataModel = Union[DataModel_BufferOrBytes, DataModel_Message, DataModel_Snapshot]
"""
TODO: Add fusion record and fusion context support
use fusion-types.{fusion-record, fusion-context};
FUSION record
record fusion-record-model {
timestamp: timestamp;
%record: fusion-record;
}
FUSION context information
record fusion-context-model {
timestamp: timestamp,
topics: list<string>,
context: fusion-context,
}
DataModel
"""


@dataclass
class ModuleSchema:
    name: str
    content_type: str
    content: str

@dataclass
class ModuleConfiguration:
    """
    Passed on initialization
    """
    properties: List[Tuple[str, str]]
    module_schemas: List[ModuleSchema]


