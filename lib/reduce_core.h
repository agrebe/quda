__global__ void REDUCE_FUNC_NAME(Kernel) (REDUCE_TYPES, QudaSumFloat *g_odata, unsigned int n) {
  unsigned int tid = threadIdx.x;
  unsigned int i = blockIdx.x*reduce_threads + threadIdx.x;
  unsigned int gridSize = reduce_threads*gridDim.x;
  
  QudaSumFloat sum = 0;
  while (i < n) {
    REDUCE_AUXILIARY(i);
    sum += REDUCE_OPERATION(i);
    i += gridSize;
  }

  extern __shared__ QudaSumFloat sdata[];
  QudaSumFloat *s = sdata + tid;
  
  s[0] = sum;
  __syncthreads();
  
  // do reduction in shared mem
  if (reduce_threads >= 1024) { if (tid < 512) { s[0] += s[512]; } __syncthreads(); }
  if (reduce_threads >= 512) { if (tid < 256) { s[0] += s[256]; } __syncthreads(); }
  if (reduce_threads >= 256) { if (tid < 128) { s[0] += s[128]; } __syncthreads(); }
  if (reduce_threads >= 128) { if (tid <  64) { s[0] += s[ 64]; } __syncthreads(); }
  
  if (tid < 32) {
    volatile QudaSumFloat *sv = s;
    if (reduce_threads >=  64) { sv[0] += sv[32]; }
    if (reduce_threads >=  32) { sv[0] += sv[16]; }
    if (reduce_threads >=  16) { sv[0] += sv[ 8]; }
    if (reduce_threads >=   8) { sv[0] += sv[ 4]; }
    if (reduce_threads >=   4) { sv[0] += sv[ 2]; }
    if (reduce_threads >=   2) { sv[0] += sv[ 1]; }
  }
  
  // write result for this block to global mem 
  if (tid == 0) g_odata[blockIdx.x] = s[0];
}

template <typename Float>
double REDUCE_FUNC_NAME(Cuda) (REDUCE_TYPES, int n, int kernel, QudaPrecision precision) {
  setBlock(kernel, n, precision);
  
  if (blasGrid.x > REDUCE_MAX_BLOCKS) {
    errorQuda("reduce_core: grid size %d must be smaller than %d", blasGrid.x, REDUCE_MAX_BLOCKS);
  }
  
  // when there is only one warp per block, we need to allocate two warps 
  // worth of shared memory so that we don't index shared memory out of bounds
  size_t smemSize = (blasBlock.x <= 32) ? blasBlock.x * 2 * sizeof(QudaSumFloat) : 
    blasBlock.x * sizeof(QudaSumFloat);

  if (blasBlock.x == 32) {
    REDUCE_FUNC_NAME(Kernel)<32><<< blasGrid, blasBlock, smemSize >>>(REDUCE_PARAMS, d_reduceFloat, n);
  } else if (blasBlock.x == 64) {
    REDUCE_FUNC_NAME(Kernel)<64><<< blasGrid, blasBlock, smemSize >>>(REDUCE_PARAMS, d_reduceFloat, n);
  } else if (blasBlock.x == 128) {
    REDUCE_FUNC_NAME(Kernel)<128><<< blasGrid, blasBlock, smemSize >>>(REDUCE_PARAMS, d_reduceFloat, n);
  } else if (blasBlock.x == 256) {
    REDUCE_FUNC_NAME(Kernel)<256><<< blasGrid, blasBlock, smemSize >>>(REDUCE_PARAMS, d_reduceFloat, n);
  } else if (blasBlock.x == 512) {
    REDUCE_FUNC_NAME(Kernel)<512><<< blasGrid, blasBlock, smemSize >>>(REDUCE_PARAMS, d_reduceFloat, n);
  } else if (blasBlock.x == 1024) {
    REDUCE_FUNC_NAME(Kernel)<1024><<< blasGrid, blasBlock, smemSize >>>(REDUCE_PARAMS, d_reduceFloat, n);
  } else {
    errorQuda("Reduction not implemented for %d threads", blasBlock.x);
  }

  // copy result from device to host, and perform final reduction on CPU
  cudaMemcpy(h_reduceFloat, d_reduceFloat, blasGrid.x*sizeof(QudaSumFloat), cudaMemcpyDeviceToHost);

  // for a tuning run, let blas_test check the error condition
  if (!blasTuning) checkCudaError();

  double cpu_sum = 0;
  for (unsigned int i = 0; i < blasGrid.x; i++) cpu_sum += h_reduceFloat[i];

  reduceDouble(cpu_sum);

  return cpu_sum;
}
