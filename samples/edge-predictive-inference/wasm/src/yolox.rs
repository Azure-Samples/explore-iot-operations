// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use crate::Settings;
use image::{imageops::FilterType, ImageReader, Limits};
use serde::{Deserialize, Serialize};
use std::io::Cursor;

pub const SIZE: usize = 416;
pub const MAX_DETECTIONS: usize = 100;
const ROWS: usize = 3549;
const COLUMNS: usize = 85;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Geometry {
    pub width: u32,
    pub height: u32,
}

impl Geometry {
    pub fn validate(&self) -> Result<(), String> {
        if self.width == 0 || self.height == 0 || self.width > 4096 || self.height > 4096 {
            return Err("Image dimensions must be in 1..=4096".into());
        }
        Ok(())
    }

    fn ratio(&self) -> f32 {
        (SIZE as f32 / self.width as f32).min(SIZE as f32 / self.height as f32)
    }
}

pub struct PreparedImage {
    pub values: Vec<f32>,
    pub geometry: Geometry,
}

#[derive(Debug, Clone, Serialize)]
pub struct Detection {
    pub label: &'static str,
    pub confidence: f32,
    pub bbox: [f32; 4],
}

pub fn prepare(jpeg: &[u8]) -> Result<PreparedImage, String> {
    if jpeg.len() > 8 * 1024 * 1024 {
        return Err("JPEG exceeds 8 MiB".into());
    }
    let mut reader = ImageReader::with_format(Cursor::new(jpeg), image::ImageFormat::Jpeg);
    let mut limits = Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let rgb = reader
        .decode()
        .map_err(|e| format!("Invalid JPEG: {e}"))?
        .to_rgb8();
    let geometry = Geometry {
        width: rgb.width(),
        height: rgb.height(),
    };
    geometry.validate()?;
    let ratio = geometry.ratio();
    let width = ((geometry.width as f32 * ratio) as u32).clamp(1, SIZE as u32);
    let height = ((geometry.height as f32 * ratio) as u32).clamp(1, SIZE as u32);
    let resized = image::imageops::resize(&rgb, width, height, FilterType::Triangle);
    let plane = SIZE * SIZE;
    let mut values = vec![114.0; 3 * plane];
    // This export expects BGR [0,255], CHW, with bottom/right padding, not ImageNet normalization.
    for (x, y, pixel) in resized.enumerate_pixels() {
        let index = y as usize * SIZE + x as usize;
        for channel in 0..3 {
            values[channel * plane + index] = f32::from(pixel[2 - channel]);
        }
    }
    Ok(PreparedImage { values, geometry })
}

pub fn decode(
    rows: &[Vec<f32>],
    image: &Geometry,
    settings: &Settings,
) -> Result<Vec<Detection>, String> {
    image.validate()?;
    settings.validate()?;
    if rows.len() != ROWS || rows.iter().any(|row| row.len() != COLUMNS) {
        return Err("Expected [1,3549,85] output_0 tensor".into());
    }
    if rows.iter().flatten().any(|v| !v.is_finite())
        || rows
            .iter()
            .any(|row| row[4..].iter().any(|v| !(0.0..=1.0).contains(v)))
    {
        return Err("Model output contains invalid numbers or probabilities".into());
    }
    let ratio = image.ratio();
    let mut candidates = Vec::new();
    let mut index = 0;
    for stride in [8, 16, 32] {
        for y in 0..SIZE / stride {
            for x in 0..SIZE / stride {
                let row = &rows[index];
                index += 1;
                let confidence = row[4] * row[5];
                if confidence < settings.score_threshold {
                    continue;
                }
                let cx = (row[0] + x as f32) * stride as f32 / ratio;
                let cy = (row[1] + y as f32) * stride as f32 / ratio;
                let width = row[2].exp() * stride as f32 / ratio;
                let height = row[3].exp() * stride as f32 / ratio;
                if ![cx, cy, width, height].iter().all(|v| v.is_finite())
                    || width <= 0.0
                    || height <= 0.0
                {
                    return Err("Decoded box must have finite coordinates and positive size".into());
                }
                let bbox = [
                    (cx - width / 2.0).clamp(0.0, image.width as f32),
                    (cy - height / 2.0).clamp(0.0, image.height as f32),
                    (cx + width / 2.0).clamp(0.0, image.width as f32),
                    (cy + height / 2.0).clamp(0.0, image.height as f32),
                ];
                if bbox[2] > bbox[0] && bbox[3] > bbox[1] {
                    candidates.push(Detection {
                        label: "person",
                        confidence,
                        bbox,
                    });
                }
            }
        }
    }
    candidates.sort_by(|a, b| b.confidence.total_cmp(&a.confidence));
    let mut detections: Vec<Detection> = Vec::new();
    for candidate in candidates {
        if detections
            .iter()
            .all(|kept| iou(&candidate.bbox, &kept.bbox) <= settings.nms_threshold)
        {
            detections.push(candidate);
            if detections.len() == MAX_DETECTIONS {
                break;
            }
        }
    }
    Ok(detections)
}

fn iou(a: &[f32; 4], b: &[f32; 4]) -> f32 {
    let intersection =
        (a[2].min(b[2]) - a[0].max(b[0])).max(0.0) * (a[3].min(b[3]) - a[1].max(b[1])).max(0.0);
    let area = |r: &[f32; 4]| (r[2] - r[0]) * (r[3] - r[1]);
    intersection / (area(a) + area(b) - intersection)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_original_coordinates_filters_non_people_and_suppresses_overlap() {
        let mut rows = vec![vec![0.0; COLUMNS]; ROWS];
        rows[0][..6].copy_from_slice(&[10., 10., 2_f32.ln(), 4_f32.ln(), 0.9, 0.8]);
        rows[1][..6].copy_from_slice(&[9., 10., 2_f32.ln(), 4_f32.ln(), 0.8, 0.8]);
        rows[2][4] = 1.0;
        rows[2][6] = 1.0;
        let image = Geometry {
            width: 832,
            height: 416,
        };
        let detections = decode(&rows, &image, &Settings::default()).unwrap();
        assert_eq!(detections.len(), 1);
        assert_eq!(detections[0].bbox, [144., 128., 176., 192.]);
        assert!((detections[0].confidence - 0.72).abs() < 0.00001);
        rows[0][4] = 1.1;
        assert!(decode(&rows, &image, &Settings::default()).is_err());
        rows[0][4] = 0.9;
        rows[0][2] = 1000.0;
        assert!(decode(&rows, &image, &Settings::default()).is_err());
        rows[0][2] = -1000.0;
        assert!(decode(&rows, &image, &Settings::default()).is_err());
    }
}
