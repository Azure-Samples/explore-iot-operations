// server.js
const express = require("express");
const app = express();

const port = process.env.PORT || 3000;

// Function to generate random temperature values in Fahrenheit
function getRandomTemperature(min, max) {
    return (Math.random() * (max - min) + min).toFixed(2);
}

let desiredTemperature = getRandomTemperature(68, 77); // Approx 20-25�C in Fahrenheit
let currentTemperature = getRandomTemperature(68, 77);
let thermostatPower = "on";

// Get Current Temperature
app.get("/api/thermostat/current", (req, res) => {
    currentTemperature = getRandomTemperature(68, 77);
    res.json({ currentTemperature: parseFloat(currentTemperature) });
});

// Get Desired Temperature
app.get("/api/thermostat/desired", (req, res) => {
    res.json({ desiredTemperature: parseFloat(desiredTemperature) });
});

// Set Desired Temperature
app.post("/api/thermostat/desired", express.json(), (req, res) => {
    if (req.body.desiredTemperature) {
        desiredTemperature = req.body.desiredTemperature;
        res.json({ message: "Desired temperature set successfully" });
    } else {
        res.status(400).json({ message: "Desired temperature is required" });
    }
});

// Get Thermostat Status
app.get("/api/thermostat/status", (req, res) => {
    currentTemperature = getRandomTemperature(68, 77);
    let status = desiredTemperature > currentTemperature ? "heating" : "cooling";
    res.json({
        status: status,
        currentTemperature: parseFloat(currentTemperature),
        desiredTemperature: parseFloat(desiredTemperature),
    });
});

// Toggle Thermostat Power
app.post("/api/thermostat/power", express.json(), (req, res) => {
    if (req.body.power === "on" || req.body.power === "off") {
        thermostatPower = req.body.power;
        res.json({ message: `Thermostat power turned ${thermostatPower}` });
    } else {
        res.status(400).json({ message: "Power state must be 'on' or 'off'" });
    }
});

app.listen(port, () => {
    console.log(`Thermostat API server running on port ${port}`);
});
