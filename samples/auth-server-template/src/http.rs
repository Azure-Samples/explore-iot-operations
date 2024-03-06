// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::{
    collections::HashMap,
    fmt::{Debug, Display, Formatter, Result as FmtResult},
};

use http_body_util::{BodyExt, Full};
use hyper::{body::Bytes, header, Method, StatusCode};

pub(crate) type HttpRequest = hyper::Request<hyper::body::Incoming>;
pub(crate) type HttpResponse = hyper::Response<Full<Bytes>>;

pub(crate) struct ParsedRequest {
    pub method: Method,
    pub version: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub body: Option<String>,
}

impl ParsedRequest {
    pub(crate) async fn from_http(req: HttpRequest) -> Result<Self, Response> {
        let method = req.method().clone();
        let uri = req.uri();
        let path = uri.path().to_string();
        let version = format!("{:?}", req.version());

        let mut query = HashMap::new();
        if let Some(q) = uri.query() {
            let parts: Vec<&str> = q.split('&').collect();

            for p in parts {
                if let Some((key, value)) = p.split_once('=') {
                    query.insert(key.to_lowercase().to_string(), value.to_string());
                } else {
                    return Err(Response::bad_request("bad query value"));
                }
            }
        }

        let mut headers = HashMap::with_capacity(req.headers().len());
        for (key, value) in req.headers() {
            let key = key.to_string();
            let value = value
                .to_str()
                .map_err(|_| Response::bad_request("bad header value"))?
                .to_string();

            headers.insert(key, value);
        }

        let body = req
            .into_body()
            .collect()
            .await
            .map_err(|_| Response::bad_request("unable to get body"))?
            .to_bytes();

        let body = if body.is_empty() {
            None
        } else {
            let body = std::str::from_utf8(&body)
                .map_err(|_| Response::bad_request("unable to parse body"))?
                .to_string();

            Some(body)
        };

        Ok(ParsedRequest {
            method,
            version,
            path,
            query,
            headers,
            body,
        })
    }
}

impl Debug for ParsedRequest {
    fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
        write!(f, "\n----\n")?;
        writeln!(f, "> {} {} {}", self.method, self.path, self.version)?;

        if !&self.query.is_empty() {
            writeln!(f, "> query: {:?}", self.query)?;
        }

        for (key, value) in &self.headers {
            writeln!(f, "> {key}: {value}")?;
        }

        if let Some(body) = &self.body {
            write!(f, "\n{body}")?;
        }

        Ok(())
    }
}

pub(crate) enum Response {
    Error { status: StatusCode, message: String },

    Json { status: StatusCode, body: String },
}

impl Response {
    pub fn bad_request(message: impl Display) -> Self {
        Response::Error {
            status: StatusCode::BAD_REQUEST,
            message: message.to_string(),
        }
    }

    pub fn not_found(message: impl Display) -> Self {
        Response::Error {
            status: StatusCode::NOT_FOUND,
            message: message.to_string(),
        }
    }

    pub fn method_not_allowed(method: &Method) -> Self {
        Response::Error {
            status: StatusCode::METHOD_NOT_ALLOWED,
            message: format!("{method} not allowed"),
        }
    }

    pub fn json(status: StatusCode, body: impl serde::Serialize) -> Self {
        let body = serde_json::to_string(&body).unwrap();

        Response::Json { status, body }
    }

    #[allow(clippy::wrong_self_convention)] // This function should consume self.
    pub fn to_http(self) -> HttpResponse {
        let mut response = hyper::Response::builder();

        let (status, body, debug_body) = match self {
            Response::Error { status, message } => {
                println!();
                println!("{message}");

                (status, Bytes::from(message), None)
            }

            Response::Json { status, body } => {
                response = response.header(header::CONTENT_TYPE, "application/json");

                (status, Bytes::from(body.clone()), Some(body))
            }
        };

        println!();
        println!("< {status}");

        let body = Full::new(body);
        let response = response.status(status).body(body).unwrap();

        for (key, value) in response.headers() {
            println!("< {}: {}", key, value.to_str().unwrap());
        }

        if let Some(body) = debug_body {
            println!();
            println!("{body}");
        }

        response
    }
}
