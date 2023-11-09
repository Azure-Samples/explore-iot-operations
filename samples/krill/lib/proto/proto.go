package proto

type Encoder interface {
	Encode(any) *Message
	Decode(*Message) any
}

type ProtoEncoder struct {
}

func New() *ProtoEncoder {
	return &ProtoEncoder{}
}

func (encoder *ProtoEncoder) Encode(message any) *Message {

	res := new(Message)

	switch option := message.(type) {
	case []any:
		for _, element := range option {
			res.Array = append(res.Array, encoder.Encode(element))
		}
	case map[string]any:

		res.Map = make(map[string]*Message)

		for k, v := range option {
			res.Map[k] = encoder.Encode(v)
		}
	case int:
		res.Options = &Message_Integer{
			Integer: int32(option),
		}
	case float64:
		res.Options = &Message_Float{
			Float: option,
		}
	case string:
		res.Options = &Message_String_{
			String_: option,
		}
	case bool:
		res.Options = &Message_Boolean{
			Boolean: option,
		}
	}

	return res
}

func (encoder *ProtoEncoder) Decode(message *Message) any {

	if len(message.Array) > 0 {

		res := make([]any, len(message.Array))

		for idx, element := range message.Array {
			res[idx] = encoder.Decode(element)
		}

		return res
	}

	if len(message.Map) > 0 {
		res := make(map[string]any)

		for k, v := range message.Map {
			res[k] = encoder.Decode(v)
		}

		return res
	}

	switch option := message.Options.(type) {
	case *Message_String_:
		return option.String_
	case *Message_Integer:
		return int(option.Integer)
	case *Message_Float:
		return option.Float
	case *Message_Boolean:
		return option.Boolean
	}

	return nil
}

type MockEncoder struct {
	OnEncode func(any) *Message
	OnDecode func(*Message) any
}

func (encoder *MockEncoder) Encode(a any) *Message {
	return encoder.OnEncode(a)
}

func (encoder *MockEncoder) Decode(a *Message) any {
	return encoder.OnDecode(a)
}
