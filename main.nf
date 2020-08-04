#!/usr/bin/env nextflow 

// set up channels
TRAIN_DIR = Channel.fromPath(params.training_10x_dir)
TRAIN_METADATA = Channel.fromPath(params.training_metadata)

// if necessary, down-sample cells to avoid memory issues 
process downsample_cells {
    conda "${baseDir}/envs/label_analysis.yaml"

    memory { 10.GB * task.attempt }
    maxRetries 5
    errorStrategy { task.attempt<=5 ? 'retry' : 'ignore' }

    input:
        file(expression_data) from TRAIN_DIR
        file(training_metadata) from TRAIN_METADATA
        
    output:
        file("expr_data_downsampled") into TRAIN_DIR_DOWNSAMPLED
        file("metadata_filtered.tsv") into TRAIN_METADATA_DOWNSAMPLED

    """
    set +e
    downsample_cells.R\
        --expression-data ${expression_data}\
        --metadata ${training_metadata}\
        --exclusions ${params.exclusions}\
        --cell-id-field ${params.cell_id_col}\
        --cell-type-field ${params.cluster_col}\
        --output-dir expr_data_downsampled\
        --metadata-upd metadata_filtered.tsv

    if [ \$? -eq  2 ];
    then
        cp -P ${expression_data} expr_data_downsampled
        cp -P ${training_metadata} metadata_filtered.tsv
        exit 0
    fi
    """
}

// produce sce object for training dataset
process create_training_sce {
    conda "${baseDir}/envs/dropletutils.yaml"

    memory { 16.GB * task.attempt }
    maxRetries 5
    errorStrategy { task.attempt<=5 ? 'retry' : 'ignore' }
    
    input:
        file(train_metadata) from TRAIN_METADATA_DOWNSAMPLED
        file(train_dir) from TRAIN_DIR_DOWNSAMPLED

    output:
        file("training_sce.rds") into TRAINING_SCE

    """
    dropletutils-read-10x-counts.R\
                --samples ${train_dir}\
                --col-names ${params.col_names}\
                --metadata-files ${train_metadata}\
                --cell-id-column ${params.cell_id_col}\
                --metadata-columns ${params.cell_id_col},${params.cluster_col}\
                --output-object-file training_sce.rds
    """ 
}


// pre-process training dataset
process preprocess_training_sce {
    conda "${baseDir}/envs/scmap.yaml"

    memory { 16.GB * task.attempt }
    maxRetries 5
    errorStrategy { task.attempt<=5 ? 'retry' : 'ignore' }

    input:
        file(train_sce) from TRAINING_SCE 

    output:
        file("train_sce_processed.rds") into TRAINING_SCE_PROC

    """
    scmap-preprocess-sce.R --input-object ${train_sce} --output-sce-object train_sce_processed.rds
    """
}


// select relevant features for training dataset 
process select_train_features {
    publishDir "${baseDir}/data/output", mode: 'copy'
    conda "${baseDir}/envs/scmap.yaml"

    memory { 16.GB * task.attempt } 
    maxRetries 5
    errorStrategy { task.attempt<=5 ? 'retry' : 'ignore' }

    input:
        file(train_sce) from TRAINING_SCE_PROC
    output:
        file("train_features.rds") into TRAINING_FEATURES

    """
    scmap-select-features.R\
                --input-object-file ${train_sce}\
                --output-object-file train_features.rds
    """
}

projection_method = params.projection_method
TRAIN_CLUSTER = Channel.create()
TRAIN_CELL = Channel.create()
// make a map to re-direct input into correct channel 
channels = ["cluster":0, "cell":1]
TRAINING_FEATURES.choice(TRAIN_CLUSTER, TRAIN_CELL){channels[projection_method]}

// obtain index for cluster-level projections 
process index_cluster {
    publishDir "${params.results_dir}"
    conda "${baseDir}/envs/scmap.yaml"

    memory { 16.GB * task.attempt }
    maxRetries 5
    errorStrategy { task.attempt<=5 ? 'retry' : 'ignore' }

    input:
        file(train_features_sce) from TRAIN_CLUSTER

    output:
        file("scmap_index_cluster.rds") into CLUSTER_INDEX

    """
    scmap-index-cluster.R\
                    --input-object-file ${train_features_sce}\
                    --cluster-col ${params.cluster_col}\
                    --train-id ${params.training_dataset_id}\
                    --output-object-file scmap_index_cluster.rds
    """
}

// obtain index for cell-level projections 
process index_cell {
    publishDir "${params.results_dir}"
    conda "${baseDir}/envs/scmap.yaml"

    memory { 16.GB * task.attempt }
    maxRetries 5
    errorStrategy { task.attempt<=5 ? 'retry' : 'ignore' }

    input:
        file(train_features_sce) from TRAIN_CELL

    output:
        file("scmap_index_cell.rds") into REF_CELL_INDEX

    """
    scmap-index-cell.R\
                 --input-object-file ${train_features_sce}\
                 --train-id ${params.training_dataset_id}\
                 --output-object-file scmap_index_cell.rds
    """
}




