# Krill

```
⠀⠀⠀⠀⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⣀⣤⣤⣀⠀⠀⠀⠀⠀⠀
⠀⠀⢀⣀⡙⠻⢶⣶⣦⣴⣶⣶⣶⠾⠛⠛⠋⠉⠉⠉⠉⠙⠃⠀⠀⠀⠀⠀
⠀⠀⠀⠉⠉⠙⠛⠛⠋⠉⠉⠡⣤⣴⣶⣶⣾⣿⣿⣿⣛⣩⣤⡤⠖⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⣴⣾⠂⣴⣦⠈⣿⣿⣿⣿⣿⣿⠿⠛⣋⠁⠀⠀⠀⠀⠀
⠀⠀⢀⣼⣿⣶⣄⡉⠻⣧⣌⣁⣴⣿⣿⣿⣿⣿⣿⡿⠛⠁⠀⠀⠀⠀⠀⠀
⠀⠀⣾⣿⣿⣿⣿⣿⣦⡈⢻⣿⣿⣿⣿⡿⠿⠛⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⡀⢻⣿⣿⣿⣿⣿⣿⣿⡄⠙⠛⠉⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⢠⣷⣄⡉⠻⢿⣿⣿⣿⠏⠠⢶⣄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⢸⣿⣿⣿⣶⣤⣈⠙⠁⠰⣦⣀⠉⠻⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠘⢿⣿⣿⣿⣿⣿⡇⠠⣦⣄⠉⠳⣤⠈⠛⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⢠⣌⣉⡉⠉⣉⡁⠀⠀⠙⠗⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠹⢿⣿⣿⣿⣿⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠙⠻⣿⣿⠟⢀⣤⡀⠀⠀⠀⠀⠀⠀⣀⣀⣠⣤⣤⣤⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠛⠿⠿⡿⠂⣀⣠⣤⣤⣤⣀⣉⣉⠉⠉⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠙⠛⠛⠛⠛⠋⠉⠉⠁
```

Krill is a highly configurable MQTT asset simulator.

## Usage

### Krill as K8s Pod

`kubectl run krill --image=azbluefin.azurecr.io/krill:latest --stdin < config.yml`

Krill runs as a pod within the desired cluster using the kubectl run command. The configuration of choice is provided via stdin of the krill process within the pod, provided in the command above using `--stdin < config.yml`. Alternative names for a configuration file may be used -- the command simply uses stdin piping to provide krill with an appropriate configuration.

See the example YAML configuration below, with comments describing the various configurable fields.

```yaml
metrics:
  type: prometheus # Type of metrics (prometheus is the only current option).
  port: 2114 # Port to host prometheus formatted metrics.
logLevel: 5 # Log level (trace: 0, debug: 1, info: 2, warn: 3, error: 4, critical: 5, fatal: 6, panic: 7)
simulation:
  target: # Target broker information.
    endpoint: localhost
    port: 1883
  sites: # List of sites, a container for one or more assets.
    - name: site2 # Name of the site.
      assetCount: 1 # Number of assets in this site.
      tags: # List of tags this asset will send.
        - id: float_0 # ID of this tag (must be unique).
          configuration: sin(float(x)) * 10.0 # Configuration of this tag.
          count: 1 # Number of copies of this tag.
        - id: float_1
          configuration: abs(sin(float(x) / 3.0) * 10.0)
          count: 1
        - id: string_0
          configuration: '"constant"'
          count: 1
        - id: string_1
          configuration: randstr(10)
          count: 1
        - id: datetime_0
          configuration: now()
          count: 1
        - id: datetime_1
          configuration: after(start, delta(now(), start) + 500)
          count: 1
        - id: int_0
          configuration: delta(now(), start)
          count: 1
        - id: int_1
          configuration: rand(0, 100)
          count: 1
        - id: indexing_0
          configuration: p.site2__int_1__0
          count: 1
        - id: indexing_1
          configuration: p.site2__int_2__0
          count: 1
        - id: square_wave
          configuration: sin(2.0 * sin(2.0 * sin(sin(2.0 * sin(sin(2.0 * sin(float(x / 2))))))))
          count: 1
        - id: saw_tooth_wave
          configuration: sin(float(x)) - (1.0 / 2.0) * sin(float(x * 2)) + (1.0 / 3.0) * sin(float(x * 3)) - (1.0 / 4.0) * sin(float(x * 4))
          count: 1
      rate: # Rate of messages sent per period of seconds (limit / periodSeconds).
        limit: 2
        messagesPerPeriod: 1
        periodSeconds: 1
        tagsPerMessage: 2 # Number of instances of a tag to render per unique tag.
      payloadFormat: JSON # Format of message (JSON, JSONTagPerMessage, BigEndian, LittleEndian)
      topicFormat: "{{.SiteName}}/{{.AssetName}}/{{.TagName}}" # Format of topic(s).
      qosLevel: 1 # QoS level of published messages.
      mqttVersion: v5 # MQTT protocol version to use for clients in this site (v3 or v5 permitted).

```

### Configuring Payload Formats

There are currently five supported types of payload formats:

1. **JSON** - Sends all rendered tags as a collection of key value pairs in one JSON object.
1. **JSONTagPerMessage** - Sends each tag individually as a JSON object in its own message.
1. **BigEndian** - Sends all tags rendered as an array of bytes, with all numeric types formatted in a big endian format.
1. **LittleEndian** - Sends all tags rendered as an array of bytes, with all numeric types formatted in a little endian format.
1. **CSV** - CSV formatted message (will flatten any objects into CSV fields).
1. **Protobuf** - Protobuf encoded message.

### Configuring Topics

The following payload formats must only use the `{{.SiteName}}` and `{{.AssetName}}` template variables in formatting their topics: JSON, BigEndian, and LittleEndian. JSONTagPerMessage must use `{{.SiteName}}`, `{{.AssetName}}`, and `{{.TagName}}`, as each tag is sent in its own topic. SiteName will always be set to the name of the site as defined in the configuration. AssetName is a concatenation of SiteName and the asset ID in the form `<SiteName>__asset_<assetID>`. TagName is a concatenation of SiteName, TagName, and the tag ID in the form `<SiteName>__<TagName>__<tagID>`.

As an example, `/site0/site0__asset_1/site0__my_tag__0` would be the topic used to publish the 1st asset's tag `my_tag` for `site0`, when using the JSONTagPerMessage format.

### Configuring Equations

Built-in functions:

1. **sin** - _(x: float) &rarr; float_ , returns the sin of x.
1. **cos** - _(x: float) &rarr; float_ , returns the cos of x.
1. **tan** - _(x: float) &rarr; float_ , returns the tan of x.
1. **asin** - _(x: float) &rarr; float_ , returns the asin of x.
1. **acos** - _(x: float) &rarr; float_ , returns the acos of x.
1. **atan** - _(x: float) &rarr; float_ , returns the atan of x.
1. **rand** - _(x: int, y: int) &rarr; int_ , picks a random number between x and y, non-inclusive of y.
1. **str** - _(x: float, y: int) &rarr; int_ , converts x to a string representation, with the number of decimal places specified by y.
1. **concat** - _(x: string, y: string) &rarr; string_ , returns the concatenation of strings x and y.
1. **randstr** - _(x: int) &rarr; string_ , returns a string of random alphabetical characters of length x.
1. **now** - _() &rarr; datetime_ , returns the current time.
1. **delta** - _(x: datetime, y: datetime) &rarr; int_ , finds the delta between datetime x and y in terms of milliseconds.
1. **int** - _(x: float) &rarr; int_ , converts the float x into an int.
1. **float** - _(x: int) &rarr; float_ , converts the int x into a float.
1. **after** - _(x: datetime, y: int) &rarr; datetime_ , adds the number of milliseconds specified by y to the datetime x.
1. **abs** - _(x: float) &rarr; float_ , returns the absolute value of x.
1. **pi** - _() &rarr; float_ , returns the value of the constant pi.

Symbols:

1. **start** - set to the time at which the asset began publishing messages.
1. **x** - set to the message number, which starts at 0 and counts up.
1. **site** - set to the name of the site.
1. **id** - set to the id of this asset.
1. **p** - set to the structure of the previous sent message, and can be indexed into to obtain previously sent values.

Valid Constants:

1. **29** - integer values.
1. **29.1** - floating point values.
1. **"strings"** - string values.

Operators:

1. **float + float**
1. **float - float**
1. **float / float**
1. **float \* float**
1. **float ^ float** (power)
1. **int + int**
1. **int - int**
1. **int / int**
1. **int \* int**
1. **int ^ int** (power)
1. **int % int** (remainder)

Example Equations:

1. **after(start, delta(now(), start) + 500)** - returns a time 500 milliseconds after the current time.
1. **start** - returns the current time.
1. **sin(float(x)) - (1.0 / 2.0) _ sin(float(x _ 2)) + (1.0 / 3.0) _ sin(float(x _ 3)) - (1.0 / 4.0) _ sin(float(x _ 4))** - a sawtooth wave.
1. **p.site0**square_wave**0** - the value of the square tooth wave tag from the immediately preceding message.
1. **randstr(rand(1, 20))** - a random string of a random length between 1 and 20 characters.
1. **concat("message - ", str(float(x), 0))** - returns a string describing "message - \<current message number\>".

### Other Notes

1. If you enter an invalid equation, errors will be logged, but the value sent will be a constant 0.
2. If you attempt to divide 0 by 0, the result will be 0.
3. If you build an int too large, overflow will occur.
4. If you build a float too large, errors will be logged once the value reaches the infinity value or the NaN value.
5. Order of operations will be preserved, but parentheses are recommended.
6. If you return p as one of your return data values, you will recursively build a larger and larger structure until the message size will be too large to send to the MQTT broker.

## Metrics

Prometheus metrics are provided by the krill simulator at the port specified in the metrics field of the configuration. The available metrics are:

1. `krill_entity_gauge` - shows the count of each system entity.
1. `krill_<siteName>_asset_publish_counter` - records the number of messages published, labeled by asset identifier.