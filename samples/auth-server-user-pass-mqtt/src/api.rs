use log::trace;
use actix_web::{http::Error, web, HttpResponse};
use crate::model::{ApiVersion, SupportedApiVersions, ClientAuthRequest};

pub(crate) const API_SUPPORTED_VERSION: &str = "0.5.0";

pub async fn authenticate(auth_query: web::Query<ApiVersion>, auth_data: web::Json<ClientAuthRequest>) -> Result<HttpResponse, Error> {    
    // TODO: this can be a security risk, check how this aligns with SFI.
    trace!("{auth_query:#?}{auth_data:#?}");

    // Add chain of validators in a separate module if this starts to bloat.
    if auth_query.api_version != API_SUPPORTED_VERSION {
        return Ok(HttpResponse::UnprocessableEntity().json(SupportedApiVersions::default()));
    }

    // TODO: add authentication logic here.
    Ok(HttpResponse::Ok()
        .content_type("text/plain")
        .body("Autnentication successful!"))
}