// Copyright (c) Microsoft. All rights reserved.

use std::{pin::Pin, task::Poll};

use openssl::{
    pkey::{PKey, Private},
    ssl::{Ssl, SslAcceptor, SslMethod, SslVerifyMode},
    x509::{store::X509StoreBuilder, X509},
};

type TlsStream = tokio_openssl::SslStream<tokio::net::TcpStream>;

type HandshakeFuture =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<TlsStream, openssl::ssl::Error>>>>;

/// A stream of incoming TLS connections, for use with a hyper server.
pub struct Incoming {
    listener: tokio::net::TcpListener,
    tls_acceptor: SslAcceptor,
    connections: futures_util::stream::FuturesUnordered<HandshakeFuture>,
}

impl Incoming {
    pub(crate) fn new(
        addr: (&str, u16),
        server_cert_chain: Vec<X509>,
        private_key: PKey<Private>,
        client_cert_issuer: Option<Vec<X509>>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let listener = std::net::TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        let listener = tokio::net::TcpListener::from_std(listener)?;

        let mut tls_acceptor = SslAcceptor::mozilla_modern(SslMethod::tls())?;
        tls_acceptor.set_private_key(&private_key)?;

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

        Ok(Incoming {
            listener,
            tls_acceptor,
            connections: Default::default(),
        })
    }
}

impl hyper::server::accept::Accept for Incoming {
    type Conn = TlsStream;
    type Error = std::io::Error;

    fn poll_accept(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> Poll<Option<Result<Self::Conn, Self::Error>>> {
        use futures_core::Stream;

        loop {
            match self.listener.poll_accept(cx) {
                Poll::Ready(Ok((stream, _))) => {
                    let stream = Ssl::new(self.tls_acceptor.context())
                        .and_then(|ssl| tokio_openssl::SslStream::new(ssl, stream));
                    let mut stream = match stream {
                        Ok(stream) => stream,
                        Err(err) => {
                            eprintln!(
                                "Dropping client that failed to complete a TLS handshake: {}",
                                err
                            );
                            continue;
                        }
                    };
                    self.connections.push(Box::pin(async move {
                        let () = Pin::new(&mut stream).accept().await?;
                        Ok(stream)
                    }));
                }

                Poll::Ready(Err(err)) => eprintln!(
                    "Dropping client that failed to completely establish a TCP connection: {}",
                    err
                ),

                Poll::Pending => break,
            }
        }

        loop {
            if self.connections.is_empty() {
                return Poll::Pending;
            }

            match Pin::new(&mut self.connections).poll_next(cx) {
                Poll::Ready(Some(Ok(stream))) => {
                    println!("Accepted connection from client");
                    return Poll::Ready(Some(Ok(stream)));
                }

                Poll::Ready(Some(Err(err))) => eprintln!(
                    "Dropping client that failed to complete a TLS handshake: {}",
                    err
                ),

                Poll::Ready(None) => {
                    println!("Shutting down web server");
                    return Poll::Ready(None);
                }

                Poll::Pending => return Poll::Pending,
            }
        }
    }
}
