//! Centralized error types for TimeTrace.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum AppError {
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Windows API error: {0}")]
    Windows(String),

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("{0}")]
    Other(String),
}
