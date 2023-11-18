# SQL Input Tool

## Quick Start

A setup script is included to create the postgres database in SQL and load a preconfigured SQL script. An example usage of the setup script would be as follows:

```sh
# ./setup.sh $K8S_NAMESPACE $DB_NAME $DB_USERNAME $DB_PASSWORD $LOCAL_SQL_FILE_PATH
./setup.sh azure-iot-operations database username password ./initialization.sql
```
