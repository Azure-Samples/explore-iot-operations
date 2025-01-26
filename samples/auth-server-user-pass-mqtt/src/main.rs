// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

mod api;
mod model;
mod username_password_authenticator;

use actix_web::{web, App, HttpServer};
use clap::Parser;
use log::info;
use model::StoredCredentials;
use openssl::ssl::{SslAcceptor, SslMethod};
use std::{
    io,
    path::{Path, PathBuf},
};
use username_password_authenticator::UsernamePasswordAuthenticator;

const BIND_ADDRESS: &str = "0.0.0.0";

#[actix_web::main]
async fn main() -> io::Result<()> {
    // Initialize logging.
    env_logger::init();
    info!("Initializing the authentication server with username and password support...");

    let options = Options::parse();

    info!("Configuring TLS for secure communication with provided server certificate and private key...");
    let mut builder = SslAcceptor::mozilla_intermediate(SslMethod::tls())?;

    // Disable TLSv1, TLSv1.1 for security reasons.
    // TODO: do not disable TLSv1.2 until it's verified that TLSv.1.3 is supported by all clients (e.g. AIO MQTT broker).
    builder.set_options(openssl::ssl::SslOptions::NO_TLSV1 | openssl::ssl::SslOptions::NO_TLSV1_1);
    builder.set_private_key_file(&options.server_key, openssl::ssl::SslFiletype::PEM)?;
    builder.set_certificate_chain_file(&options.server_cert_chain)?;

    log::info!(
        "Starting HTTPS server at https://{BIND_ADDRESS}:{}.",
        options.port
    );

    // Inject dependencies into the actix-web server to be used by the request handlers.
    // This enables unit testing and decoupling of the request handlers from the actual implementation.
    let stored_credentials = StoredCredentials {
        credential_file: PathBuf::from(&options.stored_credentials_file),
    };

    let authenticator = std::sync::Arc::new(
        // Panic if the authenticator cannot be initialized.
        UsernamePasswordAuthenticator::new(&Path::new(&stored_credentials.credential_file))
            .unwrap(),
    );

    info!("Core authenticator module initialized successfully.");

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(authenticator.clone()))
            .route(
                "/",
                web::post().to(api::authenticate::<UsernamePasswordAuthenticator>),
            )
    })
    .bind_openssl((BIND_ADDRESS, options.port), builder)?
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

    /// PBKDF2 encoded credentials file for authentication.
    #[arg(long, short = 's', value_name = "STORED_CREDENTIALS_FILE")]
    stored_credentials_file: PathBuf,
}
