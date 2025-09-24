# Use Alpine Python runtime
FROM python:3.13.6-alpine3.21

# Set the working directory in the container to /app
WORKDIR /app

# Set Python to run in unbuffered mode
ENV PYTHONUNBUFFERED=1

# Copy the current directory contents into the container at /app
ADD . /app

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Make port 8080 available to the world outside this container
EXPOSE 8080

# Run the script when the container launches
CMD ["python", "randomized-spod-sensor.py"]