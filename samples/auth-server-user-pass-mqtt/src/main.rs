mod api;
mod model;

use actix_web::{middleware, web, App, HttpServer};
use clap::Parser;
use log::info;
use openssl::ssl::{SslAcceptor, SslMethod};
use std::{io, path::PathBuf};

const BIND_ADDRESS: &str = "0.0.0.0";

#[actix_web::main]
async fn main() -> io::Result<()> {
    // Initialize logging.
    env_logger::init();
    info!("Initiating authentication server for username password...");
    let options = Options::parse();

    info!("Configuring TLS for secure communication...");
    let mut builder = SslAcceptor::mozilla_intermediate(SslMethod::tls())?;

    builder.set_private_key_file(&options.server_key, openssl::ssl::SslFiletype::PEM)?;
    builder.set_certificate_chain_file(&options.server_cert_chain)?;
    
    // TODO: validate add support for client certificate validation.
    if let Some(client_cert_issuer) = &options.client_cert_issuer {
        builder.set_ca_file(client_cert_issuer)?;
        builder.set_verify(openssl::ssl::SslVerifyMode::PEER | openssl::ssl::SslVerifyMode::FAIL_IF_NO_PEER_CERT);
    } else {
        builder.set_verify(openssl::ssl::SslVerifyMode::NONE);
    }    

    log::info!("Starting HTTPS server at https://{BIND_ADDRESS}:{}", options.port);

    HttpServer::new(|| {
        App::new()
            // enable logger
            .wrap(middleware::Logger::default())
            // simple root handler
            .service(web::resource("/").route(web::post().to(api::authenticate)))
    })
    .bind_openssl(format!("{BIND_ADDRESS}:{}", options.port), builder)?
    .run()
    .await
}

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
