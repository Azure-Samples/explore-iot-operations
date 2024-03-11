// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#![warn(clippy::all, clippy::pedantic)]

/// Handles authentication of MQTT connections.
mod authenticate;

/// Handles parsing and generating HTTP requests.
mod http;

use std::{path::PathBuf, pin::Pin};

use clap::Parser;
use hyper::server::conn::http1::Builder as ServerBuilder;
use hyper_util::rt::TokioIo;
use openssl::{
    pkey::{PKey, Private},
    ssl::{Ssl, SslAcceptor, SslContext, SslMethod, SslVerifyMode},
    x509::{store::X509StoreBuilder, X509},
};
use tokio_openssl::SslStream;

/// Command-line options for this program.
#[derive(Parser)]
struct Options {
    /// Port to listen on.
    #[arg(long, short, value_name = "PORT")]
    port: u16,

    /// TLS server cert chain to present to connecting clients.
    #[arg(long, short = 'c', value_name = "SERVER_CERT_CHAIN")]
    server_cert_chain: PathBuf,

    /// Private key of TLS server cert.
    #[arg(long, short = 'k', value_name = "SERVER_KEY")]
    server_key: PathBuf,

    /// Optional CA certs for validating client certificates. Omit to disable
    /// client certificate validation.
    #[arg(long, short = 'i', value_name = "CLIENT_CERT_ISSUER")]
    client_cert_issuer: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let options = Options::parse();

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

    let tls_context = tls_context(server_cert_chain, &server_key, client_cert_issuer)?;

    println!("Will listen on 0.0.0.0:{}", options.port);
    let listener = std::net::TcpListener::bind(("0.0.0.0", options.port))?;
    listener.set_nonblocking(true)?;
    let listener = tokio::net::TcpListener::from_std(listener)?;

    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(err) => {
                println!("Failed to accept TCP connection: {err}");

                continue;
            }
        };

        let ssl = Ssl::new(&tls_context).expect("invalid TLS context");
        let mut stream = match SslStream::new(ssl, stream) {
            Ok(stream) => stream,
            Err(err) => {
                println!("Failed to create SSLStream: {err}");

                continue;
            }
        };

        if let Err(err) = Pin::new(&mut stream).accept().await {
            println!("Failed to establish TLS connection: {err}");

            continue;
        }

        let stream = TokioIo::new(stream);

        tokio::spawn(async move {
            if let Err(err) = ServerBuilder::new()
                .serve_connection(stream, hyper::service::service_fn(process_req))
                .await
            {
                println!("HTTP server error: {err:?}");
            }
        });
    }
}

/// Create a TLS context from the given X.509 credentials.
fn tls_context(
    server_cert_chain: Vec<X509>,
    private_key: &PKey<Private>,
    client_cert_issuer: Option<Vec<X509>>,
) -> Result<SslContext, Box<dyn std::error::Error>> {
    let mut tls_acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls())?;
    tls_acceptor.set_private_key(private_key)?;

    let mut server_cert_chain = server_cert_chain.into_iter();

    if let Some(leaf_cert) = server_cert_chain.next() {
        tls_acceptor.set_certificate(&leaf_cert)?;
    } else {
        return Err(
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "no certs provided").into(),
        );
    }

    if let Some(issuer) = client_cert_issuer {
        let mut store = X509StoreBuilder::new()?;

        for cert in issuer {
            store.add_cert(cert)?;
        }

        tls_acceptor.set_verify_cert_store(store.build())?;
        tls_acceptor.set_verify(SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT);
    }

    for cert in server_cert_chain {
        tls_acceptor.add_extra_chain_cert(cert)?;
    }

    let tls_acceptor = tls_acceptor.build();

    Ok(tls_acceptor.into_context())
}

/// Parse an HTTP request and authenticate the connecting client.
async fn process_req(
    req: http::HttpRequest,
) -> Result<http::HttpResponse, std::convert::Infallible> {
    let req = match http::ParsedRequest::from_http(req).await {
        Ok(req) => req,
        Err(response) => return Ok(response.to_http()),
    };

    // This prints the incoming HTTP request. Useful for debugging, but note that
    // it may print sensitive data.
    println!("{req:?}");

    let response = authenticate::authenticate(req).await;

    Ok(response.to_http())
}
