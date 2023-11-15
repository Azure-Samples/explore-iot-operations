// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/// Handles authentication of MQTT connections.
mod authenticate;

/// Handles parsing and generating HTTP requests.
mod http;

/// Handles TLS and socket communication.
mod incoming;

use std::path::PathBuf;

use openssl::{pkey::PKey, x509::X509};
use structopt::StructOpt;

/// Command-line options for this program.
#[derive(StructOpt)]
struct Options {
    /// Port to listen on.
    #[structopt(long, short, value_name = "PORT")]
    port: u16,

    /// TLS server cert chain to present to connecting clients.
    #[structopt(long, short = "c", value_name = "SERVER_CERT_CHAIN")]
    server_cert_chain: PathBuf,

    /// Private key of TLS server cert.
    #[structopt(long, short = "k", value_name = "SERVER_KEY")]
    server_key: PathBuf,

    /// Optional CA certs for validating client certificates. Omit to disable
    /// client certificate validation.
    #[structopt(long, short = "i", value_name = "CLIENT_CERT_ISSUER")]
    client_cert_issuer: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let options = Options::from_args();

    let server_key = std::fs::read(&options.server_key)?;
    let server_key = PKey::private_key_from_pem(&server_key)?;

    let server_cert_chain = std::fs::read(&options.server_cert_chain)?;
    let server_cert_chain = X509::stack_from_pem(&server_cert_chain)?;

    let client_cert_issuer = if let Some(path) = options.client_cert_issuer {
        let certs = std::fs::read(path)?;
        let certs = X509::stack_from_pem(&certs)?;

        Some(certs)
    } else {
        None
    };

    println!("Will listen on 0.0.0.0:{}", options.port);
    let incoming = incoming::Incoming::new(
        ("0.0.0.0", options.port),
        server_cert_chain,
        server_key,
        client_cert_issuer,
    )?;

    hyper::Server::builder(incoming)
        .serve(hyper::service::make_service_fn(move |_| {
            let service = hyper::service::service_fn(process_req);

            async move { Ok::<_, std::convert::Infallible>(service) }
        }))
        .await?;

    Ok(())
}

/// Parse an HTTP request and authenticate the connecting client.
async fn process_req(
    req: hyper::Request<hyper::Body>,
) -> Result<hyper::Response<hyper::Body>, std::convert::Infallible> {
    let req = match http::ParsedRequest::from_http(req).await {
        Ok(req) => req,
        Err(response) => return Ok(response.to_http()),
    };

    // This prints the incoming HTTP request. Useful for debugging, but note that
    // it may print sensitive data.
    println!("{:?}", req);

    let response = authenticate::authenticate(req).await;

    Ok(response.to_http())
}
