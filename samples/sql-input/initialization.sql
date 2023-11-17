-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

CREATE TABLE assetinfo (
  assetID varchar(255),
  serialNumber varchar(255),
  name varchar(255),
  site varchar(255),
  maintenanceStatus varchar(255)
);


INSERT INTO assetinfo (assetID, serialNumber, name, site, maintenanceStatus)
VALUES
('Sea_O1', 'SN001', 'Contoso', 'Seattle', 'Done'),
('Red_O1', 'SN002', 'Contoso', 'Redmond', 'Upcoming'),
('Tac_O1', 'SN003', 'Contoso', 'Tacoma', 'Overdue'),
('Sea_S1', 'SN004', 'Contoso', 'Seattle', 'Done'),
('Red_S1', 'SN005', 'Contoso', 'Redmond', 'Upcoming'),
('Tac_O1', 'SN006', 'Contoso', 'Tacoma', 'Overdue'),
('Sea_M1', 'SN007', 'Contoso', 'Seattle', 'Done'),
('Red_M1', 'SN008', 'Contoso', 'Redmond', 'Upcoming'),
('Tac_M1', 'SN009', 'Contoso', 'Tacoma', 'Overdue'),
('Tac_S1', 'SN010', 'Contoso', 'Tacoma', 'Upcoming');