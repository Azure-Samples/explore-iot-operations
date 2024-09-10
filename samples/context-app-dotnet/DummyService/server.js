// server.js
const basicAuth = require('basic-auth');
const express = require("express");
const app = express();

const port = 80;

const USERNAME = process.env.SERVICE_USERNAME;
const PASSWORD = process.env.SERVICE_PASSWORD;

// In-memory store for users (for demonstration purposes)
const users = {
    [USERNAME]: PASSWORD
};

// Middleware to check Basic Authentication
const authenticate = (req, res, next) => {
    const user = basicAuth(req);
    if (user && users[user.name] === user.pass) {
        next();
    } else {
        res.set('WWW-Authenticate', 'Basic realm="example"');
        res.status(401).json({ error: 'Unauthorized' });
    }
};

// Apply the authentication middleware to all routes
app.use(authenticate);

app.get("/contexts/:key", (req, res) => {
    const key = req.params.key;
    const contextList = [
        {
            country: "us",
            viscosity: 0.5,
            sweetness: 0.8,
            particle_size: 0.7,
            overall: 0.4
        },
        {
            country: "fr",
            viscosity: 0.6,
            sweetness: 0.85,
            particle_size: 0.75,
            overall: 0.45
        },
        {
            country: "jp",
            viscosity: 0.53,
            sweetness: 0.83,
            particle_size: 0.73,
            overall: 0.43
        },
        {
            country: "uk",
            viscosity: 0.51,
            sweetness: 0.81,
            particle_size: 0.71,
            overall: 0.41
        }
    ];
    res.json(contextList);
});

app.listen(80, () => {
    console.log(`Server running on port ${port}`);
});