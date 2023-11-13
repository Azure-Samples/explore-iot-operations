# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

FROM python:3.10-slim

COPY requirements.txt .
RUN python -m pip install --no-cache -r requirements.txt

WORKDIR /app
COPY . /app

CMD ["python", "subscriber.py"]
